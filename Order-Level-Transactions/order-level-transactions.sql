WITH 
valid_marketplace AS (
  SELECT id_marketplace
  FROM pesanan
  WHERE marketplace IN ('MANUAL', 'TIKTOK_SHOP', 'SHOPEE')
  GROUP BY id_marketplace
  HAVING COUNT(DISTINCT marketplace) = 2
),

param_dates AS (
    SELECT 
        '{{from}}'::date AS start_date,
        '{{to}}'::date + INTERVAL '1 day' AS end_date
),

pesanan_bersih AS (
  SELECT *
  FROM (
    SELECT 
      p.id, 
      p.created_at::DATE AS tanggal, 
      p.marketplace as mp, 
      p.id_marketplace,
      t.nama as nama_toko, 
      p.toko_id as toko_id, 
      p.data ->> 'platform' as platform,
      p.atur_by, 
      g.nama as gudang, 
      p.customer ->> 'nama' AS nama_cust, 
      p.id_marketplace as id_mp, 
      p.harga as harga, 
      p.status as status,
      p.customer ->> 'nama_toko' as nama_toko2,
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
    JOIN param_dates pdt ON TRUE 
    WHERE p.created_at >= pdt.start_date 
      AND p.created_at < pdt.end_date
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

shopee_per_order AS (
    SELECT p.id,
        (pphs.escrow_amount * 100.0 / 111.0) AS total_omni,
        ROUND((pphs.order_selling_price - pphs.voucher_from_seller)::NUMERIC*100/111, 2) AS total_fat
        --((pphs.order_selling_price - pphs.voucher_from_seller) * 100.0 / 111.0)::NUMERIC(12,2) AS total_fat
    FROM pesanan_bersih p
    JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
    WHERE p.mp = 'SHOPEE'
),

tp_agg AS (
  SELECT
    order_id,
    -- jumlahkan nilai berbeda per order_id
    SUM(DISTINCT total_settlement_amount) AS total_settlement_amount
  FROM tiktok_pencairan
  GROUP BY order_id
),

tiktok_per_order AS (
    SELECT 
        p.id,
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
        (ppht.original_total_product_price - ppht.seller_discount)::NUMERIC * 100 / 111 AS total_fat
    FROM pesanan_bersih p
    JOIN pesanan_pembentuk_harga_tiktok_shop ppht ON p.id = ppht.pesanan_id
    JOIN pesanan_detail pd ON p.id = pd.pesanan_id
    JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
    LEFT JOIN tp_agg tp ON p.id_marketplace = tp.order_id
    WHERE p.mp = 'TIKTOK_SHOP'
    GROUP BY p.id, tp.total_settlement_amount, ppht.original_total_product_price, ppht.seller_discount
),

manual_per_order AS (
    SELECT 
        p.id,
        p.harga * 100 / 111 AS total_omni,
        ROUND(SUM(p.harga)::NUMERIC * 100 / 111,2) AS total_fat
    FROM pesanan_bersih p
    JOIN users_omni uo ON p.atur_by = uo.id
    JOIN param_dates pdt ON TRUE 
    WHERE p.mp = 'MANUAL'
        AND p.tanggal >= pdt.start_date
    	AND p.tanggal < pdt.end_date
        AND uo.name NOT IN ('Admin Offline', 'dig1line')
        AND p.status NOT IN ('BARU', 'DIKEMBALIKAN', 'DIBATALKAN', 'GAGAL_KIRIM')
        AND NOT (p.nama_cust ILIKE '%GUDANG%' AND p.toko_id = 221)
        AND NOT (p.nama_cust ILIKE '%SHOPEE%' AND p.toko_id = 221)
),

omni_all AS (
    SELECT * FROM shopee_per_order
    UNION ALL
    SELECT * FROM tiktok_per_order
    UNION ALL
    SELECT * FROM manual_per_order
),

hpp AS (
    SELECT 
        p.id,
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
    JOIN param_dates pdt ON TRUE 
    WHERE p.created_at >= pdt.start_date
    	AND p.created_at < pdt.end_date
        AND p.status NOT IN ('DIBATALKAN', 'GAGAL_KIRIM', 'BARU','DIKEMBALIKAN')
    GROUP BY p.id
),

packing AS (
    SELECT 
        p.id,
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
    JOIN param_dates pdt ON TRUE 
    WHERE p.created_at >= pdt.start_date
    	AND p.created_at < pdt.end_date
    GROUP BY p.id
),

ongkir AS (
    SELECT 
        p.id,
        (p.data ->> 'ongkir')::NUMERIC AS total_ongkir
    FROM pesanan p
    JOIN param_dates pdt ON TRUE 
    WHERE p.created_at >= pdt.start_date
    	AND p.created_at < pdt.end_date
)

SELECT DISTINCT ON (pb.id)
    pb.id AS "ID ORDER", pb.tanggal AS "TANGGAL", pb.id_mp AS "ID MP", 
    pb.mp AS "MARKETPLACE", pb.nama_cust AS "NAMA CUSTOMER", 
    pb.gudang AS "GUDANG", pb.platform AS "PLATFORM",
    CASE WHEN pb.nama_toko = 'TOKO RIVA' THEN pb.nama_toko2
    ELSE pb.nama_toko
    END AS "TOKO",
    REPLACE(TO_CHAR(om.total_omni, 'FM999G999G999'),',','.') AS "OMNI",
    --REPLACE(TO_CHAR(om.total_fat, 'FM999G999G999'),',','.') AS "FAT",
    REPLACE(TO_CHAR(h.total_hpp, 'FM999G999G999'),',','.') AS "HPP",
    REPLACE(TO_CHAR(pk.biaya_packing, 'FM999G999G999'),',','.') AS "PACKING",
    REPLACE(TO_CHAR(o.total_ongkir, 'FM999G999G999'),',','.') AS "ONGKIR"
FROM pesanan_bersih pb
LEFT JOIN omni_all om ON pb.id = om.id
LEFT JOIN hpp h ON pb.id = h.id
LEFT JOIN packing pk ON pb.id = pk.id
LEFT JOIN ongkir o ON pb.id = o.id


ORDER BY pb.id, pb.tanggal;