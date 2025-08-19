--WITH pesanan_bersih AS (
--    SELECT p.id, p.toko_id, p.marketplace, p.created_at, p.atur_by, p.id_marketplace
--    FROM pesanan p
--    JOIN toko t ON p.toko_id = t.id
--    WHERE 
--        p.created_at >= '2025-05-01'
--        AND (
--            (p.marketplace = 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
--                AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
--                AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND t.nama = 'TOKO RIVA'))
--            OR (p.marketplace <> 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU', 'DIKEMBALIKAN'))
--        )
--),
WITH 
valid_marketplace AS (
  SELECT id_marketplace
  FROM pesanan
  WHERE marketplace IN ('MANUAL', 'TIKTOK_SHOP', 'SHOPEE')
  GROUP BY id_marketplace
  HAVING COUNT(DISTINCT marketplace) = 2
),

pesanan_bersih AS (
  SELECT *
  FROM (
    SELECT 
      p.id, p.toko_id, p.marketplace, p.created_at, p.atur_by, p.id_marketplace,
      -- untuk menghitung pesanan yg diinput 2x dari MP sama Manual
      ROW_NUMBER() OVER (
        PARTITION BY p.id_marketplace 
        ORDER BY 
          CASE 
          -- yg dihitung yg dari MP dgn catatan ada harganya agar nanti nyesuain pencairan
            WHEN p.marketplace <> 'MANUAL' AND p.harga > 0 THEN 1
          -- kondisi kedua: kalau yg dari MP harganya 0, maka yg dihitung yg dari diatur Manual
            WHEN p.marketplace = 'MANUAL' AND p.harga > 0 THEN 2
            ELSE 3
          END
      ) AS urutan
    FROM pesanan p
    JOIN gudang g ON p.gudang_id = g.id
    JOIN toko t ON p.toko_id = t.id
    LEFT JOIN valid_marketplace vm ON p.id_marketplace = vm.id_marketplace
    --JOIN param_dates pdt ON TRUE 
    WHERE p.created_at >= '2025-05-01'
      --AND p.created_at < pdt.end_date
      AND (
        (p.marketplace = 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
          AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND p.toko_id = 221)
          AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND p.toko_id = 221))
        OR (p.marketplace <> 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN'))
      )
      AND p.toko_id NOT IN (345,151)
  ) x
  WHERE urutan = 1
),

shopee_total AS (
    SELECT 
        TRIM(TO_CHAR(p.created_at, 'MONTH')) AS bulan,
        EXTRACT(MONTH FROM p.created_at) AS month_order,
        SUM(pphs.escrow_amount)*100/111 AS total_omni,
        ROUND(SUM(pphs.order_selling_price - pphs.voucher_from_seller)::NUMERIC*100/111,2) AS total_fat
    FROM pesanan_bersih p
    JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
    WHERE p.marketplace = 'SHOPEE'
    GROUP BY TRIM(TO_CHAR(p.created_at, 'MONTH')), EXTRACT(MONTH FROM p.created_at)
),

tp_agg AS (
  SELECT
    order_id,
    -- jumlahkan nilai berbeda per order_id
    SUM(DISTINCT total_settlement_amount) AS total_settlement_amount
  FROM tiktok_pencairan
  GROUP BY order_id
),

tiktok_total AS (
  WITH pesanan_perhitungan AS (
    SELECT
        p.toko_id,
        p.id,
        ppht.total_amount,
        TRIM(TO_CHAR(p.created_at, 'MONTH')) AS bulan,
        EXTRACT(MONTH FROM p.created_at) AS month_order,
        /* Jika ada pencairan (hasil agregasi tp_agg), pakai itu.
           Kalau tidak ada, fallback ke rumus per-produk (pakai MAX agar tidak dobel karena join SKU). */
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
    --JOIN param_dates pdx ON p.created_at >= pdx.start_date AND p.created_at < pdx.end_date
    WHERE p.marketplace = 'TIKTOK_SHOP'
      AND p.status NOT IN ('BARU','DIBATALKAN','GAGAL_KIRIM','DIKEMBALIKAN')
      AND p.created_at >= '2025-05-01'
    GROUP BY
      p.id, p.toko_id, ppht.total_amount, tp.total_settlement_amount,
      ppht.original_total_product_price, ppht.seller_discount
  )

  SELECT
  	  bulan, 
      month_order,
      ROUND(SUM(total_omni), 2) AS total_omni,
      ROUND(SUM(total_fat), 2)  AS total_fat
  FROM pesanan_perhitungan
  GROUP BY bulan, month_order
  ORDER BY bulan
),

manual_total AS (
    SELECT 
        TRIM(TO_CHAR(p.created_at, 'MONTH')) AS bulan,
        EXTRACT(MONTH FROM p.created_at) AS month_order,
        SUM(p.harga) * 100 / 111 AS total_omni,
        ROUND(SUM(p.harga)::NUMERIC * 100 / 111,2) AS total_fat
    FROM pesanan p
    JOIN toko t ON p.toko_id = t.id
    JOIN users_omni uo ON p.atur_by = uo.id
    WHERE
        p.marketplace = 'MANUAL'
        AND p.created_at >= '2025-05-01'
        AND uo.name NOT IN ('Admin Offline', 'dig1line')
        AND p.data ->> 'platform' NOT IN ('TIKTOK_SHOP_MANUAL','SHOPEE_MANUAL')
        AND p.status NOT IN ('BARU', 'DIKEMBALIKAN', 'DIBATALKAN', 'GAGAL_KIRIM')
        AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
        AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE%' AND t.nama = 'TOKO RIVA')
        --AND NOT ((p.customer ->> 'nama') ILIKE '%NAKAMA%' AND t.nama = 'TOKO RIVA')
    GROUP BY TRIM(TO_CHAR(p.created_at, 'MONTH')), EXTRACT(MONTH FROM p.created_at)
),

omni_total_semua AS (
    SELECT bulan, month_order, SUM(total_omni) AS total_omni, SUM(total_fat) AS total_fat
    FROM (
        SELECT * FROM shopee_total
        UNION ALL
        SELECT * FROM tiktok_total
        UNION ALL
        SELECT * FROM manual_total
    ) semua
    GROUP BY bulan, month_order
),

iklan AS (
    SELECT TRIM(bulan) AS bulan, SUM(total_biaya) AS total_iklan FROM (
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')) AS bulan, SUM(cost) AS total_biaya FROM tiktok_ads_manager GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')), SUM(biaya_iklan) FROM tiktok_iklan_gmv_max GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')), SUM(biaya_iklan) FROM tiktok_iklan_booster GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(waktu_dibuat, 'MONTH')), SUM(perkiraan_pembayaran_komisi_standar) FROM tiktok_affiliator GROUP BY TRIM(TO_CHAR(waktu_dibuat, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')), SUM(biaya) FROM shopee_iklan GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')), SUM(biaya) FROM shopee_iklan_live GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(reporting_starts, 'MONTH')), SUM(amount_spent) FROM shopee_cpas_internal GROUP BY TRIM(TO_CHAR(reporting_starts, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')), SUM(pengeluaran_idr) FROM shopee_cpas_eksternal GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(waktu_pesanan, 'MONTH')), SUM(pengeluaran) FROM shopee_afiliator GROUP BY TRIM(TO_CHAR(waktu_pesanan, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')), SUM(biaya_iklan) FROM shopee_estimasi_affiliator GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
        UNION ALL
        SELECT TRIM(TO_CHAR(tanggal, 'MONTH')), SUM(pengeluaran_idr) FROM shopee_cpas_google GROUP BY TRIM(TO_CHAR(tanggal, 'MONTH'))
    ) semua_iklan GROUP BY bulan
),
-- CEK DUPLIKAT ID PESANAN
hpp AS (
    SELECT 
        TRIM(TO_CHAR(p.created_at, 'MONTH')) AS bulan,
        SUM(
            CASE
                WHEN pds.nama ILIKE '%Habbie Telon%' AND pds.nama ILIKE '%100 ml%' THEN (pds.qty::NUMERIC * 31000 * 100/111)
                WHEN pds.nama ILIKE '%Paramorina Madu%' THEN (pds.qty::NUMERIC * 29970 * 100/111) + (pds.qty::NUMERIC*500)
                WHEN pds.nama ILIKE '%Paramorina Tetes%' THEN (pds.qty::NUMERIC * 29970 * 100/111) + (pds.qty::NUMERIC*500)
                WHEN pds.nama ILIKE '%Vitabumin Madu 130%' THEN (pds.qty::NUMERIC * 29970 * 100/111)
                WHEN pds.nama ILIKE '%Vitabumin Madu 60%' THEN (pds.qty::NUMERIC * 17760 * 100/111)
                WHEN pds.nama ILIKE '%Protabumin Careos%' THEN (pds.qty::NUMERIC * 63300 * 100/111) + (pds.qty::NUMERIC*7500)
                WHEN pds.nama ILIKE '%Protabumin Nutrimom%' THEN (pds.qty::NUMERIC * 43300 * 100/111) + (pds.qty::NUMERIC*5500)
                WHEN pds.nama ILIKE '%Yayle%' THEN (pds.qty::NUMERIC * 22500)
                WHEN pds.nama ILIKE '%Habbie MKP%' THEN (pds.qty::NUMERIC * 35000 * 100/111)
                WHEN pds.nama ILIKE '%Habbie Telon%' AND pds.nama ILIKE '%60 ml%' THEN (pds.qty::NUMERIC * 23200 * 100/111)
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
    WHERE 1=1
    	and p.toko_id NOT IN (151,345)
        AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND toko_id = 221)
        AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND toko_id = 221)
        AND p.status NOT IN ('DIBATALKAN', 'GAGAL_KIRIM', 'BARU','DIKEMBALIKAN')
        and p.created_at >= '2025-05-01'
    GROUP BY TRIM(TO_CHAR(p.created_at, 'MONTH'))
),

packing AS (
    WITH per_pesanan AS (
        SELECT 
            p.id,
            DATE_TRUNC('month', p.created_at)::DATE AS bulan,
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
        WHERE 
            p.created_at >= '2025-05-01'
            AND (
                (p.marketplace = 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
                    AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
                    AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND t.nama = 'TOKO RIVA')
                )
                OR (p.marketplace <> 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN'))
            )
        GROUP BY p.id, DATE_TRUNC('month', p.created_at)
    )
    SELECT 
        TRIM(TO_CHAR(bulan, 'MONTH')) AS bulan,
        SUM(biaya_packing) AS total_packing
    FROM per_pesanan
    GROUP BY TRIM(TO_CHAR(bulan, 'MONTH'))
),

beban AS (
    SELECT 
    TRIM(TO_CHAR(TO_DATE(b.bulan::text, 'MM'), 'MONTH')) AS bulan,
    CASE
    	WHEN b.bulan = EXTRACT(MONTH FROM current_date) THEN
        	SUM(DISTINCT nilai)*DATE_PART('day', current_date - date_trunc('month', current_date))/DATE_PART('day', (date_trunc('month', current_date) + interval '1 month - 1 day'))
        ELSE SUM(DISTINCT nilai)
    END AS total_beban
    FROM beban b
    JOIN beban_toko bt ON b.id = bt.beban_id
    --WHERE b.bulan = EXTRACT(MONTH FROM current_date)
    GROUP BY TRIM(TO_CHAR(TO_DATE(b.bulan::text, 'MM'), 'MONTH')), b.bulan
),

ongkir AS (
	SELECT 
    	TRIM(TO_CHAR(p.created_at, 'MONTH')) AS bulan,
        SUM((p.data ->> 'ongkir')::NUMERIC) AS total_ongkir
    FROM pesanan p 
    WHERE 
    	p.created_at >= '2025-05-01'
    	and p.status not in ('DIBATALKAN', 'DIKEMBALIKAN', 'GAGAL_KIRIM', 'BARU')
    GROUP BY TRIM(TO_CHAR(p.created_at, 'MONTH'))
)


SELECT 
    ots.bulan AS "BULAN",
    REPLACE(TO_CHAR(ots.total_omni, 'FM999G999G999G999'),',','.') AS "GRAND TOTAL OMNI",
    REPLACE(TO_CHAR(ots.total_fat, 'FM999G999G999G999'),',','.') AS "GRAND TOTAL FAT",
    REPLACE(TO_CHAR(COALESCE(o.total_ongkir, 0), 'FM999G999G999G999'),',','.') AS "ONGKIR",
    REPLACE(TO_CHAR(COALESCE(h.total_hpp, 0), 'FM999G999G999G999'),',','.') AS "TOTAL HPP",
    REPLACE(TO_CHAR(COALESCE(b.total_beban, 0), 'FM999G999G999G999'),',','.') AS "BEBAN",
    REPLACE(TO_CHAR(COALESCE(i.total_iklan, 0), 'FM999G999G999G999'),',','.') AS "IKLAN",
    REPLACE(TO_CHAR(COALESCE(p.total_packing, 0), 'FM999G999G999G999'),',','.') AS "PACKING",
    REPLACE(TO_CHAR(
      (ots.total_omni - 
      (COALESCE(o.total_ongkir, 0) +
       COALESCE(h.total_hpp, 0) +
       COALESCE(b.total_beban, 0) +
       COALESCE(i.total_iklan, 0) +
       COALESCE(p.total_packing, 0))
    ), 'FM999G999G999G999'),',','.') AS "LABA",
    ROUND((ots.total_omni / NULLIF((COALESCE(p.total_packing, 0) + COALESCE(b.total_beban, 0) + COALESCE(i.total_iklan, 0)), 0))::numeric, 2) AS "RASIO IKLAN",
   -- ROUND(ots.total_omni / NULLIF((COALESCE(p.total_packing, 0) + COALESCE(b.total_beban, 0) + COALESCE(i.total_iklan, 0)), 0)::numeric, 2) AS "RASIO IKLAN",
  --  ROUND(((ots.total_omni - 
    --  (COALESCE(o.total_ongkir, 0) +
      -- COALESCE(h.total_hpp, 0) +
      -- COALESCE(b.total_beban, 0) +
      -- COALESCE(i.total_iklan, 0) +
      -- COALESCE(p.total_packing, 0))) / NULLIF(ots.total_omni, 0)::numeric * 100), 2) || '%' AS "% LABA"
	ROUND((((ots.total_omni - 
  (COALESCE(o.total_ongkir, 0) +
   COALESCE(h.total_hpp, 0) +
   COALESCE(b.total_beban, 0) +
   COALESCE(i.total_iklan, 0) +
   COALESCE(p.total_packing, 0))) / NULLIF(ots.total_omni, 0))::numeric * 100), 2) || '%' AS "% LABA"

FROM omni_total_semua ots
LEFT JOIN hpp h ON h.bulan = ots.bulan
LEFT JOIN iklan i ON i.bulan = ots.bulan
LEFT JOIN packing p ON p.bulan = ots.bulan
LEFT JOIN beban b ON b.bulan = ots.bulan
LEFT JOIN ongkir o ON o.bulan = ots.bulan
ORDER BY ots.month_order;