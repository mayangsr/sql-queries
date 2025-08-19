-- Definisi parameter tanggal untuk rentang laporan
WITH param_dates AS (
    SELECT 
        '{{from}}'::date AS start_date, -- Tanggal mulai laporan (inklusif)
        '{{to}}'::date AS end_date    -- Tanggal akhir laporan (inklusif)
),

-- === OMNI & FAT ===
omni_fat AS (
    SELECT 
        p.toko_id AS toko,
        -- Menghitung total omset (escrow_amount) dan FAT (order_selling_price - voucher_from_seller)
        -- Dikalikan 100/111 untuk asumsi menghilangkan PPN 11%
        SUM(pphs.escrow_amount) * 100.0 / 111.0 AS total_omni,
        SUM(pphs.order_selling_price - pphs.voucher_from_seller) * 100.0 / 111.0 AS total_fat
    FROM pesanan p
    JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
    JOIN param_dates pd ON true
    WHERE 
        p.marketplace = 'SHOPEE'
        AND p.created_at >= pd.start_date
        AND p.created_at < (pd.end_date + INTERVAL '1 day') -- Mengambil data hingga akhir hari end_date
        AND p.status NOT IN ('BARU', 'DIBATALKAN', 'GAGAL_KIRIM', 'DIKEMBALIKAN') -- Filter status pesanan yang valid
    GROUP BY p.toko_id
),

-- === BEBAN (Affiliator, Content Creator, Live) ===
beban AS (
  WITH param_dates_inner AS (
      SELECT * FROM param_dates -- Menggunakan parameter tanggal dari CTE utama
  ),
  param AS (
    -- Mendapatkan kombinasi unik import_id, toko_id, jenis beban
    SELECT DISTINCT b.import_id, bt.toko_id, b.jenis
    FROM beban_toko bt
    JOIN beban b ON bt.beban_id = b.id
  ),
  jumlah_pesanan_sejenis AS (
    -- Menghitung jumlah pesanan untuk semua toko yang relevan dengan jenis beban tertentu
    -- dalam rentang tanggal laporan
    SELECT b.import_id, b.jenis,
           COUNT(DISTINCT p.id) AS jumlah_pesanan_semua_toko
    FROM pesanan p
    JOIN beban_toko bt ON p.toko_id = bt.toko_id
    JOIN beban b ON bt.beban_id = b.id
    JOIN param_dates_inner pd ON true
    WHERE p.status NOT IN ('DIBATALKAN', 'GAGAL_KIRIM', 'BARU', 'DIKEMBALIKAN')
      AND p.created_at >= pd.start_date
      AND p.created_at < (pd.end_date + INTERVAL '1 day')
      AND b.tahun = EXTRACT(YEAR FROM pd.start_date) -- Beban dihitung untuk bulan/tahun start_date
      AND b.bulan = EXTRACT(MONTH FROM pd.start_date)
    GROUP BY b.import_id, b.jenis
  ),
  jumlah_pesanan_toko AS (
    -- Menghitung jumlah pesanan untuk masing-masing toko yang relevan dengan jenis beban tertentu
    -- dalam rentang tanggal laporan, hanya untuk marketplace SHOPEE
    SELECT b.import_id, bt.toko_id, b.jenis,
           COUNT(DISTINCT p.id) AS jumlah_pesanan_toko_ini
    FROM pesanan p
    JOIN beban_toko bt ON p.toko_id = bt.toko_id
    JOIN beban b ON bt.beban_id = b.id
    JOIN param_dates_inner pd ON true
    WHERE p.status NOT IN ('DIBATALKAN', 'GAGAL_KIRIM', 'BARU', 'DIKEMBALIKAN')
      AND p.created_at >= pd.start_date
      AND p.created_at < (pd.end_date + INTERVAL '1 day')
      AND p.marketplace = 'SHOPEE' -- Pastikan hanya pesanan Shopee yang dihitung untuk distribusi beban
      AND b.tahun = EXTRACT(YEAR FROM pd.start_date)
      AND b.bulan = EXTRACT(MONTH FROM pd.start_date)
    GROUP BY b.import_id, bt.toko_id, b.jenis
  ),
  beban_total AS (
    -- Menghitung total nilai beban bulanan dan informasi tanggal untuk proporsi
    SELECT b.import_id, bt.toko_id, b.jenis,
           EXTRACT(DAY FROM (DATE_TRUNC('month', pd.start_date) + INTERVAL '1 month - 1 day')) AS hari_dalam_bulan,
           (pd.end_date - pd.start_date + 1) AS jumlah_hari_rentang, -- Jumlah hari dalam rentang laporan
           SUM(b.nilai) AS nilai_bulanan
    FROM beban_toko bt
    JOIN beban b ON bt.beban_id = b.id
    JOIN param_dates_inner pd ON true
    WHERE b.bulan = EXTRACT(MONTH FROM pd.start_date) -- Ambil beban untuk bulan start_date
      AND b.tahun = EXTRACT(YEAR FROM pd.start_date)  -- Ambil beban untuk tahun start_date
    GROUP BY b.import_id, bt.toko_id, b.jenis, pd.start_date, pd.end_date -- Grup juga by pd untuk akses variabel
  ),
  beban_proporsional AS (
    -- Proporsikan beban bulanan ke rentang hari yang ditentukan
    SELECT 
      import_id, toko_id, jenis,
      ROUND((nilai_bulanan * jumlah_hari_rentang / NULLIF(hari_dalam_bulan, 0))::NUMERIC, 2) AS total_beban_pro_rata
    FROM beban_total
  ),
  nilai_beban AS (
    -- Distribusikan beban pro-rata berdasarkan proporsi pesanan toko
    SELECT 
      p.toko_id,
      bp.jenis,
      ROUND((t.jumlah_pesanan_toko_ini::NUMERIC / NULLIF(s.jumlah_pesanan_semua_toko, 0)) * bp.total_beban_pro_rata, 2) AS nilai
    FROM param p
    LEFT JOIN jumlah_pesanan_sejenis s ON s.import_id = p.import_id AND s.jenis = p.jenis
    LEFT JOIN jumlah_pesanan_toko t ON t.import_id = p.import_id AND t.toko_id = p.toko_id AND t.jenis = p.jenis
    LEFT JOIN beban_proporsional bp ON bp.import_id = p.import_id AND bp.toko_id = p.toko_id AND bp.jenis = p.jenis
    WHERE t.jumlah_pesanan_toko_ini IS NOT NULL AND bp.toko_id IS NOT NULL
  )
  SELECT
    toko_id AS toko,
    SUM(nilai) FILTER (WHERE jenis = 'AFFILIATOR') AS beban_am,
    SUM(nilai) FILTER (WHERE jenis = 'CONTENT_CREATOR') AS beban_cc,
    SUM(nilai) FILTER (WHERE jenis = 'LIVE') AS beban_live
  FROM nilai_beban
  GROUP BY toko_id
),

-- === IKLAN ===
iklan AS (
    WITH param_dates_inner AS (
        SELECT * FROM param_dates
    ),
    shopee_iklan_total AS (
        SELECT toko_id AS toko, SUM(biaya) AS total_biaya
        FROM shopee_iklan
        JOIN param_dates_inner pd ON true
        WHERE tanggal >= pd.start_date AND tanggal < (pd.end_date + INTERVAL '1 day')
        GROUP BY toko_id
    ),
    shopee_iklan_live_total AS (
        SELECT toko_id AS toko, SUM(biaya) AS total_biaya
        FROM shopee_iklan_live
        JOIN param_dates_inner pd ON true
        WHERE tanggal >= pd.start_date AND tanggal < (pd.end_date + INTERVAL '1 day')
        GROUP BY toko_id
    ),
    shopee_cpas_internal_total AS (
        SELECT toko_id AS toko, SUM(amount_spent) AS total_spent
        FROM shopee_cpas_internal
        JOIN param_dates_inner pd ON true
        WHERE reporting_starts >= pd.start_date AND reporting_starts < (pd.end_date + INTERVAL '1 day')
        GROUP BY toko_id
    ),
    shopee_cpas_eksternal_total AS (
        SELECT toko_id AS toko, SUM(pengeluaran_idr) AS total_spent
        FROM shopee_cpas_eksternal scpas
        JOIN param_dates_inner pd ON true
        WHERE tanggal >= pd.start_date AND tanggal < (pd.end_date + INTERVAL '1 day')
        GROUP BY toko_id
    ),
    shopee_aff_total AS (
        SELECT toko_id AS toko, SUM(pengeluaran) AS total_spent
        FROM shopee_afiliator
        JOIN param_dates_inner pd ON true
        WHERE waktu_pesanan >= pd.start_date AND waktu_pesanan < (pd.end_date + INTERVAL '1 day')
        GROUP BY toko_id
    ),
    shopee_estimasi_aff AS (
    	SELECT toko_id as toko, SUM(biaya_iklan) AS total_spent
        FROM shopee_estimasi_affiliator
        JOIN param_dates_inner pd ON true
        WHERE tanggal >= pd.start_date AND tanggal < (pd.end_date + INTERVAL '1 day')
    	GROUP BY toko_id
    ),
    shopee_cpas_google AS (
    	SELECT toko_id as toko, SUM(pengeluaran_idr) AS total_spent
        FROM shopee_cpas_google
        JOIN param_dates_inner pd ON true
        WHERE tanggal >= pd.start_date AND tanggal < (pd.end_date + INTERVAL '1 day')
        GROUP BY toko_id
    )

    SELECT 
        COALESCE(sit.toko, slt.toko, sci.toko, sce.toko, sa.toko, sea.toko, sg.toko) AS toko,
        -- Penjumlahan semua biaya iklan non-afiliator
        COALESCE(sit.total_biaya, 0) + COALESCE(slt.total_biaya, 0) + COALESCE(sci.total_spent, 0) + COALESCE(sce.total_spent, 0) + COALESCE(sg.total_spent, 0) AS total_iklan,
        -- Biaya afiliator (dipisahkan sesuai permintaan)
        COALESCE(sa.total_spent, 0) + COALESCE(sea.total_spent, 0)AS total_aff
    FROM shopee_iklan_total sit
    FULL OUTER JOIN shopee_iklan_live_total slt ON sit.toko = slt.toko
    FULL OUTER JOIN shopee_cpas_internal_total sci ON COALESCE(sit.toko, slt.toko) = sci.toko
    FULL OUTER JOIN shopee_cpas_eksternal_total sce ON COALESCE(sit.toko, slt.toko, sci.toko) = sce.toko
    FULL OUTER JOIN shopee_aff_total sa ON COALESCE(sit.toko, slt.toko, sci.toko, sce.toko) = sa.toko
    FULL OUTER JOIN shopee_estimasi_aff sea ON COALESCE(sit.toko, slt.toko, sci.toko, sce.toko, sa.toko) = sea.toko
    FULL OUTER JOIN shopee_cpas_google sg ON COALESCE(sit.toko, slt.toko, sci.toko, sce.toko, sa.toko, sea.toko) = sg.toko
),

-- === PACKING ===
packing AS (
    WITH param_dates_inner AS (
        SELECT * FROM param_dates
    ),
    per_pesanan AS (
        SELECT p.id, p.toko_id AS toko,
               SUM(pds.qty) AS total_qty,
               CASE -- Logic biaya packing berdasarkan total QTY per pesanan
                 WHEN SUM(pds.qty) > 0 AND SUM(pds.qty) <= 3 THEN 2300
                 WHEN SUM(pds.qty) > 3 AND SUM(pds.qty) <= 10 THEN 2800
                 WHEN SUM(pds.qty) > 10 AND SUM(pds.qty) <= 60 THEN 7400
                 WHEN SUM(pds.qty) > 60 THEN 11400
                 ELSE 0
               END AS biaya_packing
        FROM pesanan p
        JOIN pesanan_detail pd ON p.id = pd.pesanan_id
        JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
        JOIN toko t ON p.toko_id = t.id
        JOIN param_dates_inner pd_p ON true
        WHERE p.created_at >= pd_p.start_date AND p.created_at < (pd_p.end_date + INTERVAL '1 day')
          AND ( -- Filter khusus untuk pesanan manual (mengecualikan internal/konsinyasi) dan pesanan marketplace
            (p.marketplace = 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
             AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
             AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND t.nama = 'TOKO RIVA'))
            OR (p.marketplace <> 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU', 'DIKEMBALIKAN'))
          )
        GROUP BY p.id, p.toko_id
    )
    SELECT 
        toko,
        SUM(biaya_packing) AS total_packing
    FROM per_pesanan
    GROUP BY toko
),

-- === HPP (Harga Pokok Penjualan) ===
hpp AS (
    WITH param_dates_inner AS (
        SELECT * FROM param_dates
    ),
    produk_hpp AS (
        SELECT 
            p.toko_id as toko,
            SUM(
                CASE -- Logika perhitungan HPP berdasarkan nama produk dan kuantitas
                    WHEN pds.nama ILIKE '%Habbie Telon%' AND pds.nama ILIKE '%100 ml%' THEN (pds.qty::NUMERIC * 31000 * 100.0/111.0)
                    WHEN pds.nama ILIKE '%Paramorina Madu%' THEN (pds.qty::NUMERIC * 29970 * 100.0/111.0) + (pds.qty::NUMERIC*500)
                    WHEN pds.nama ILIKE '%Paramorina Tetes%' THEN (pds.qty::NUMERIC * 29970 * 100.0/111.0) + (pds.qty::NUMERIC*500)
                    WHEN pds.nama ILIKE '%Vitabumin Madu 130%' THEN (pds.qty::NUMERIC * 29970 * 100.0/111.0)
                    WHEN pds.nama ILIKE '%Vitabumin Madu 60%' THEN (pds.qty::NUMERIC * 17760 * 100.0/111.0)
                    WHEN pds.nama ILIKE '%Protabumin Careos%' THEN (pds.qty::NUMERIC * 63300 * 100.0/111.0) + (pds.qty::NUMERIC*7500)
                    WHEN pds.nama ILIKE '%Protabumin Nutrimom%' THEN (pds.qty::NUMERIC * 43300 * 100.0/111.0) + (pds.qty::NUMERIC*5500)
                    WHEN pds.nama ILIKE '%Yayle%' THEN (pds.qty::NUMERIC * 22500)
                    WHEN pds.nama ILIKE '%Habbie MKP%' THEN (pds.qty::NUMERIC * 35000 * 100.0/111.0)
                    WHEN pds.nama ILIKE '%Habbie Telon%' AND pds.nama ILIKE '%60 ml%' THEN (pds.qty::NUMERIC * 23200 * 100.0/111.0)
                    WHEN pds.nama ILIKE '%GM. TP%' THEN (pds.qty::NUMERIC * 4900 * 100/111)
                    WHEN pds.nama ILIKE '%Habbie Tester%' THEN (pds.qty::NUMERIC * 8700 * 100/111)
                    WHEN pds.nama ILIKE '%Gm.Md Banner%' THEN (pds.qty::NUMERIC * 16000 * 100/111)
                    WHEN pds.nama ILIKE '%Habbie Box Isi 3%' THEN (pds.qty::NUMERIC * 20000 * 100/111)
                    WHEN pds.nama ILIKE '%Habbie Box Isi 5%' THEN (pds.qty::NUMERIC * 21000 * 100/111)
                    WHEN pds.nama ILIKE '%Cessa%' THEN (pds.qty::NUMERIC * 27000 * 100/111)
                    WHEN pds.nama ILIKE '%Lega%' THEN (pds.qty::NUMERIC * 18500 * 100/111)
                    ELSE 0
                END
            ) AS total_hpp
        FROM pesanan p
        JOIN pesanan_detail pd ON p.id = pd.pesanan_id
        JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
        JOIN toko t ON p.toko_id = t.id 
        JOIN param_dates_inner pd_p ON true
        WHERE 
        	p.created_at >= pd_p.start_date AND p.created_at < (pd_p.end_date + INTERVAL '1 day')
          AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU', 'DIKEMBALIKAN')
        GROUP BY p.toko_id
    )
    SELECT toko, total_hpp FROM produk_hpp
),

-- === GABUNG SEMUA TOKO YANG PUNYA DATA DI SALAH SATU CTE ===
all_toko AS (
  SELECT toko FROM omni_fat
  UNION
  SELECT toko FROM beban
  UNION
  SELECT toko FROM iklan
  UNION
  SELECT toko FROM packing
  UNION
  SELECT toko FROM hpp
)

-- === FINAL OUTPUT ===
SELECT
    CASE -- Formatting nama toko
        WHEN t.nama LIKE '%habbie.official%' THEN INITCAP('habbie official')
        WHEN t.nama LIKE '%habbie.store%' THEN INITCAP('habbie store')
        WHEN t.nama LIKE '%PROTABUMIN OFFICIAL SHOP%' THEN INITCAP('PROTABUMIN OFFICIAL SHOP')
        ELSE t.nama -- Jika tidak ada pola yang cocok, tampilkan nama asli
    END AS "TOKO",
    -- Format nilai numerik menjadi string Rupiah
    REPLACE(TO_CHAR(COALESCE(o.total_omni, 0), 'FM999G999G999G999'), ',', '.') AS "OMSET",
    REPLACE(TO_CHAR(COALESCE(o.total_fat, 0), 'FM999G999G999G999'), ',', '.') AS "OMSET FAT",
    REPLACE(TO_CHAR(COALESCE(pc.total_packing, 0), 'FM999G999G999G999'), ',', '.') AS "PACKING",
    REPLACE(TO_CHAR(COALESCE(b.beban_am, 0), 'FM999G999G999G999'), ',', '.') AS "BEBAN AM",
    REPLACE(TO_CHAR(COALESCE(b.beban_cc, 0), 'FM999G999G999G999'), ',', '.') AS "BEBAN CC",
    REPLACE(TO_CHAR(COALESCE(b.beban_live, 0), 'FM999G999G999G999'), ',', '.') AS "BEBAN LIVE",
    REPLACE(TO_CHAR(COALESCE(i.total_iklan, 0), 'FM999G999G999G999'), ',', '.') AS "IKLAN",
    REPLACE(TO_CHAR(COALESCE(i.total_aff, 0), 'FM999G999G999G999'), ',', '.') AS "AFFILIATOR",
    REPLACE(TO_CHAR(COALESCE(h.total_hpp, 0), 'FM999G999G999G999'), ',', '.') AS "HPP",
    ROUND(o.total_omni / NULLIF(COALESCE(i.total_iklan, 0), 0), 2) AS "RASIO IKLAN",
        COALESCE(ROUND(COALESCE(o.total_omni, 0) / NULLIF((
        COALESCE(b.beban_am, 0) + 
        COALESCE(b.beban_cc, 0) + 
        COALESCE(b.beban_live, 0)
    ), 0), 2), 0) AS "RASIO BEBAN",
    -- Perhitungan rasio
    ROUND(COALESCE(o.total_omni, 0) / NULLIF((
        COALESCE(pc.total_packing, 0) + 
        COALESCE(b.beban_am, 0) + 
        COALESCE(b.beban_cc, 0) + 
        COALESCE(b.beban_live, 0) + 
        COALESCE(i.total_iklan, 0) + 
        COALESCE(i.total_aff, 0)
        -- HPP tidak termasuk dalam RASIO ALL berdasarkan definisi awal query Anda
    ), 0), 2) AS "RASIO ALL",

    --==LABA (OMSET - PACKING - HPP - BEBAN - IKLAN) 
    --COALESCE(o.total_omni, 0) -
    --COALESCE(pc.total_packing, 0) -
    --COALESCE(h.total_hpp, 0) -
    --COALESCE(b.beban_am, 0) -
    --COALESCE(b.beban_cc, 0) -
    --COALESCE(b.beban_live, 0) -
    --COALESCE(i.total_iklan, 0) - 
    --COALESCE(i.total_aff, 0) AS 
    --== % LABA (LABA/OMSET)
    ROUND(((COALESCE(o.total_omni, 0) -
    COALESCE(pc.total_packing, 0) -
    COALESCE(h.total_hpp, 0) -
    COALESCE(b.beban_am, 0) -
    COALESCE(b.beban_cc, 0) -
    COALESCE(b.beban_live, 0) -
    COALESCE(i.total_iklan, 0) - 
    COALESCE(i.total_aff, 0))/COALESCE(o.total_omni, 0))*100,2) || '%' AS "% LABA"
FROM all_toko at
LEFT JOIN omni_fat o ON at.toko = o.toko
LEFT JOIN beban b ON at.toko = b.toko
LEFT JOIN iklan i ON at.toko = i.toko
LEFT JOIN packing pc ON at.toko = pc.toko
LEFT JOIN hpp h ON at.toko = h.toko
LEFT JOIN toko t ON t.id = at.toko
WHERE COALESCE(o.total_omni, 0) > 0 -- Hanya tampilkan toko dengan omset positif
ORDER BY "TOKO";