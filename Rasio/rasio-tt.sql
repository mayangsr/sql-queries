-- === OMNI & FAT ===
WITH tp_agg AS (
  SELECT
    order_id,
    SUM(DISTINCT total_settlement_amount) AS total_settlement_amount
  FROM tiktok_pencairan
  GROUP BY order_id
),

omni_fat AS (
  WITH pesanan_perhitungan AS (
    SELECT
        p.toko_id,
        p.id,
        ppht.total_amount,

        
        COALESCE(
          tp.total_settlement_amount,
          MAX(CASE
              WHEN pds.nama ILIKE '%Vitabumin Madu 130%' OR pds.nama ILIKE '%Paramorina%' OR pds.nama ILIKE '%Yayle%' OR pds.nama ILIKE '%Cessa%' THEN 
                (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.1425) * 100 / 111
              WHEN pds.nama ILIKE '%Vitabumin Madu 60%' OR pds.nama ILIKE '%Protabumin%' THEN 
                (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.16) * 100 / 111
              WHEN pds.nama ILIKE '%Habbie%' THEN 
                (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.165) * 100 / 111
              ELSE
                (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.1425) * 100 / 111
          END)
        ) AS total_omni,

        -- DPP FAT
        (ppht.original_total_product_price - ppht.seller_discount)::NUMERIC * 100 / 111 AS total_fat

    FROM pesanan p
    JOIN pesanan_pembentuk_harga_tiktok_shop ppht ON p.id = ppht.pesanan_id
    JOIN pesanan_detail pd ON p.id = pd.pesanan_id
    JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
    LEFT JOIN tp_agg tp ON p.id_marketplace = tp.order_id
    WHERE p.marketplace = 'TIKTOK_SHOP'
      AND p.created_at >= '{{from}}'::date
      AND p.created_at <  '{{to}}'::date + INTERVAL '1 day'
      AND p.status NOT IN ('BARU','DIBATALKAN','GAGAL_KIRIM','DIKEMBALIKAN')
    GROUP BY
      p.id, p.toko_id, ppht.total_amount, tp.total_settlement_amount,
      ppht.original_total_product_price, ppht.seller_discount
  )

  SELECT
      toko_id AS toko,
      ROUND(SUM(total_omni), 2) AS total_omni,
      ROUND(SUM(total_fat), 2)  AS total_fat
  FROM pesanan_perhitungan
  GROUP BY toko_id
),

-- === BEBAN ===
beban AS (
  WITH param AS (
    SELECT DISTINCT b.import_id, bt.toko_id, b.jenis
    FROM beban_toko bt
    JOIN beban b ON bt.beban_id = b.id
  ),
  jumlah_pesanan_sejenis AS (
    SELECT b.import_id, b.jenis,
           COUNT(DISTINCT p.id) AS jumlah_pesanan_semua_toko
    FROM pesanan p
    JOIN beban_toko bt ON p.toko_id = bt.toko_id
    JOIN beban b ON bt.beban_id = b.id
    WHERE p.status NOT IN ('DIBATALKAN', 'GAGAL_KIRIM', 'BARU','DIKEMBALIKAN')
      AND p.created_at >= '{{from}}'::date
      AND p.created_at < '{{to}}'::date + INTERVAL '1 day'
      AND b.tahun = EXTRACT(YEAR FROM p.created_at)
      AND b.bulan = EXTRACT(MONTH FROM p.created_at)
    GROUP BY b.import_id, b.jenis
  ),
  jumlah_pesanan_toko AS (
    SELECT b.import_id, bt.toko_id, b.jenis,
           COUNT(DISTINCT p.id) AS jumlah_pesanan_toko_ini
    FROM pesanan p
    JOIN beban_toko bt ON p.toko_id = bt.toko_id
    JOIN beban b ON bt.beban_id = b.id
    WHERE p.status NOT IN ('DIBATALKAN', 'GAGAL_KIRIM', 'BARU','DIKEMBALIKAN')
      AND p.created_at >= '{{from}}'::date
      AND p.created_at < '{{to}}'::date + INTERVAL '1 day'
      AND p.marketplace = 'TIKTOK_SHOP'
      AND b.tahun = EXTRACT(YEAR FROM p.created_at)
      AND b.bulan = EXTRACT(MONTH FROM p.created_at)
    GROUP BY b.import_id, bt.toko_id, b.jenis
  ),
  beban_total AS (
    SELECT b.import_id, bt.toko_id, b.jenis,
           EXTRACT(DAY FROM (DATE_TRUNC('month', '{{from}}'::date) + INTERVAL '1 month - 1 day')) AS hari_dalam_bulan,
           ('{{to}}'::date - '{{from}}'::date + 1) AS jumlah_hari_rentang,
           SUM(b.nilai) AS nilai_bulanan
    FROM beban_toko bt
    JOIN beban b ON bt.beban_id = b.id
    WHERE b.bulan = EXTRACT(MONTH FROM '{{from}}'::date)
      AND b.tahun = EXTRACT(YEAR FROM '{{from}}'::date)
    GROUP BY b.import_id, bt.toko_id, b.jenis
  ),
  beban_proporsional AS (
    SELECT 
      import_id, toko_id, jenis,
      ROUND((nilai_bulanan * jumlah_hari_rentang / NULLIF(hari_dalam_bulan, 0))::NUMERIC, 2) AS total_beban
    FROM beban_total
  ),
  nilai_beban AS (
    SELECT 
      p.toko_id,
      bp.jenis,
      ROUND((t.jumlah_pesanan_toko_ini::NUMERIC / NULLIF(s.jumlah_pesanan_semua_toko, 0)) * bp.total_beban, 2) AS nilai
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
  WITH tiktok_ads_manager_total AS (
    SELECT 
      toko_id,
      SUM(cost) AS total_ads_manager
    FROM tiktok_ads_manager
    WHERE tanggal >= '{{from}}'::date AND tanggal < '{{to}}'::date + INTERVAL '1 day'
    GROUP BY toko_id
  ),
  tt_gmv_max_total AS (
    SELECT 
      toko_id,
      SUM(biaya_iklan) AS total_gmv_max
    FROM tiktok_iklan_gmv_max
    WHERE tanggal >= '{{from}}'::date AND tanggal < '{{to}}'::date + INTERVAL '1 day'
    GROUP BY toko_id
  ),
  tt_booster_total AS (
    SELECT 
      toko_id,
      SUM(biaya_iklan) AS total_booster
    FROM tiktok_iklan_booster
    WHERE tanggal >= '{{from}}'::date AND tanggal < '{{to}}'::date + INTERVAL '1 day'
    GROUP BY toko_id
  ),
  tt_aff_total AS (
    SELECT 
      toko_id::text as toko_id,
      SUM(perkiraan_pembayaran_komisi_standar) AS total_aff
    FROM tiktok_affiliator
    WHERE waktu_dibuat >= '{{from}}'::date AND waktu_dibuat < '{{to}}'::date + INTERVAL '1 day'
    GROUP BY toko_id
  )
  SELECT 
    COALESCE(am.toko_id, gm.toko_id, bo.toko_id, af.toko_id) AS toko,
    COALESCE(am.total_ads_manager, 0) AS total_ads_manager,
    COALESCE(gm.total_gmv_max, 0) AS total_gmv_max,
    COALESCE(bo.total_booster, 0) AS total_booster,
    COALESCE(af.total_aff, 0) AS total_aff,
    COALESCE(am.total_ads_manager, 0) + 
    COALESCE(gm.total_gmv_max, 0) + 
    COALESCE(bo.total_booster, 0) AS total_iklan
  FROM tiktok_ads_manager_total am
  FULL OUTER JOIN tt_gmv_max_total gm ON am.toko_id = gm.toko_id
  FULL OUTER JOIN tt_booster_total bo ON COALESCE(am.toko_id, gm.toko_id) = bo.toko_id
  FULL OUTER JOIN tt_aff_total af ON COALESCE(am.toko_id, gm.toko_id, bo.toko_id) = af.toko_id
),

-- === PACKING ===
packing AS (
    WITH per_pesanan AS (
        SELECT p.id, p.toko_id AS toko,
               SUM(pds.qty) AS total_qty,
               CASE 
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
        WHERE p.created_at >= '{{from}}'::date AND p.created_at < '{{to}}'::date + INTERVAL '1 day'
          AND (
            (p.marketplace = 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
             AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
             AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND t.nama = 'TOKO RIVA'))
            OR (p.marketplace <> 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN'))
          )
        GROUP BY p.id, p.toko_id
    )
    SELECT 
        toko,
        SUM(biaya_packing) AS total_packing
    FROM per_pesanan
    GROUP BY toko
),

-- === HPP ===
hpp AS (
    WITH produk_hpp AS ( 
        SELECT 
            p.toko_id as toko,
            SUM(
                CASE 
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
        WHERE p.created_at >= '{{from}}'::date AND p.created_at < '{{to}}'::date + INTERVAL '1 day'
          
            AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
          
        GROUP BY p.toko_id
    )
    SELECT toko, total_hpp FROM produk_hpp
)	

-- === FINAL OUTPUT ===
SELECT 
    CASE
        WHEN nama LIKE '%aksi buah hati%' THEN INITCAP('Aksi Buah Hati')
        WHEN nama LIKE '%Buah Hati Bunda%' THEN INITCAP('Buah Hati Bunda')
        WHEN nama LIKE '%Habbie Aromatic%' THEN INITCAP('Habbie Aromatic')
        WHEN nama LIKE '%protabuminofficial%' THEN INITCAP('protabumin official')
        WHEN nama LIKE '%TelonSultan%' THEN INITCAP('Telon Sultan')
        WHEN nama LIKE '%vita kids%' THEN INITCAP('vita kids')
    END AS "TOKO",
    REPLACE(TO_CHAR(COALESCE(o.total_omni, 0), 'FM999G999G999'), ',', '.') AS "OMSET",
    REPLACE(TO_CHAR(COALESCE(o.total_fat, 0), 'FM999G999G999G999'), ',', '.') AS "OMSET FAT",
    REPLACE(TO_CHAR(COALESCE(pc.total_packing, 0), 'FM999G999G999'), ',', '.') AS "PACKING",
    REPLACE(TO_CHAR(COALESCE(b.beban_am, 0), 'FM999G999G999'), ',', '.') AS "BEBAN AM",
    REPLACE(TO_CHAR(COALESCE(b.beban_cc, 0), 'FM999G999G999'), ',', '.') AS "BEBAN CC",
    REPLACE(TO_CHAR(COALESCE(b.beban_live, 0), 'FM999G999G999'), ',', '.') AS "BEBAN LIVE",
    REPLACE(TO_CHAR(COALESCE(i.total_iklan, 0), 'FM999G999G999'), ',', '.') AS "IKLAN",
    REPLACE(TO_CHAR(COALESCE(i.total_aff, 0), 'FM999G999G999'), ',', '.') AS "AFFILIATOR",
    REPLACE(TO_CHAR(COALESCE(h.total_hpp, 0), 'FM999G999G999'), ',', '.') AS "HPP",
    ROUND(o.total_omni / NULLIF(COALESCE(i.total_iklan, 0), 0), 2) AS "RASIO IKLAN",
    ROUND(o.total_omni / NULLIF((COALESCE(b.beban_am, 0) + COALESCE(b.beban_cc, 0) + COALESCE(b.beban_live, 0)), 0), 2) AS "RASIO BEBAN",
    ROUND(o.total_omni / NULLIF((COALESCE(pc.total_packing, 0) + COALESCE(b.beban_am, 0) + COALESCE(b.beban_cc, 0) + COALESCE(b.beban_live, 0) + COALESCE(i.total_iklan, 0) + COALESCE(i.total_aff, 0)), 0), 2) AS "RASIO ALL",
    
    --==%LABA
    ROUND(((COALESCE(o.total_omni, 0) -
    COALESCE(pc.total_packing, 0) -
    COALESCE(h.total_hpp, 0) -
    COALESCE(b.beban_am, 0) -
    COALESCE(b.beban_cc, 0) -
    COALESCE(b.beban_live, 0) -
    COALESCE(i.total_iklan, 0) - 
    COALESCE(i.total_aff, 0))/COALESCE(o.total_omni, 0))*100,2) || '%' AS "% LABA"
FROM omni_fat o
FULL OUTER JOIN beban b ON o.toko = b.toko
FULL OUTER JOIN iklan i ON o.toko = i.toko::int OR b.toko = i.toko::int
FULL OUTER JOIN packing pc ON o.toko = pc.toko OR b.toko = pc.toko OR i.toko::int = pc.toko
LEFT JOIN hpp h ON h.toko = COALESCE(o.toko, b.toko, i.toko::int, pc.toko)
LEFT JOIN toko t ON t.id = COALESCE(o.toko, b.toko, i.toko::int, pc.toko)
WHERE o.total_omni > 0
ORDER BY t.nama;