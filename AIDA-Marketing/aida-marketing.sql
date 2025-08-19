WITH param_dates AS (
    SELECT 
        '{{from}}'::date AS start_date, -- Tanggal mulai laporan (inklusif)
        '{{to}}'::date + INTERVAL '1 day' AS end_date    -- Tanggal akhir laporan (inklusif)
),

param_dates_last_month AS (
	SELECT
		('{{from}}'::date - INTERVAL '1 month') AS start_date,
		('{{to}}'::date - INTERVAL '1 month' + INTERVAL '1 day') AS end_date
),

kol_ig AS (
	SELECT 
    	week1_views AS awareness,
        (week1_koment + week1_like + week1_share) AS interest,
        posting_tanggal_posting as tanggal,
		week1_komen_brand as desire
        from sheet2_kol_ig
        join param_dates pdt on true
        where posting_tanggal_posting >= pdt.start_date and posting_tanggal_posting < pdt.end_date
),

kol_tt AS (
	SELECT
    	views as awareness,
        (koment + "like") as interest,
        tanggal_posting as tanggal,
        (views * ctr) as desire
        from sheet2_kol_tt
        join param_dates pdt on true
        where tanggal_posting >= pdt.start_date and tanggal_posting < pdt.end_date
),

am_tasya AS (
	SELECT
    	average_views_video_1_pekan AS awareness,
        (comment + likes) AS interest,
        tanggal_upload as tanggal,
        ROUND((average_views_video_1_pekan * ctr)) AS desire
        FROM sheet2_am_tasya
        JOIN param_dates pdt ON TRUE
        WHERE tanggal_upload >= pdt.start_date AND tanggal_upload < pdt.end_date
),

am_tama AS (
	SELECT
    	average_views_video_1_pekan AS awareness,
        (comment + likes) AS interest,
        tanggal_upload as tanggal,
        (average_views_video_1_pekan * ctr) AS desire
        FROM sheet2_am_tama
        JOIN param_dates pdt ON TRUE
        WHERE tanggal_upload >= pdt.start_date AND tanggal_upload < pdt.end_date
),

internal AS (
	SELECT 
    	(COALESCE(week1_views,0) + COALESCE(week1_yellowcart_avg_views,0)) as awareness,
        tanggal,
        (COALESCE(week1_comment, 0) + COALESCE(week1_like, 0) + COALESCE(week1_share, 0) + 
        COALESCE(week1_yellowcart_comment, 0) + COALESCE(week1_yellowcart_likes, 0)) AS interest,
        --(COALESCE(week1_comment_brand, 0) + (COALESCE(week1_yellowcart_avg_views, 0) * COALESCE(week1_yellowcart_ctr,0))) AS desire
        (COALESCE(week1_comment_brand, 0) + COALESCE(week1_yellowcart_clicks, 0)) AS desire
        FROM sheet2_internal
        JOIN param_dates pdt ON TRUE
        WHERE tanggal >= pdt.start_date AND tanggal < pdt.end_date
),

all_kol as (
	SELECT * from kol_ig
    UNION ALL
    SELECT * FROM kol_tt
),

all_am as (
	SELECT * FROM am_tasya
    UNION ALL
	SELECT * FROM am_tama
),

gt_shopee AS (
    SELECT 
    	COUNT(p.id) as id_order,
        p.toko_id AS toko,
        SUM(pphs.escrow_amount) * 100.0 / 111.0 AS total_omni,
        SUM(pphs.order_selling_price - pphs.voucher_from_seller) * 100.0 / 111.0 AS total_fat
    FROM pesanan p
    JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
    JOIN param_dates pdt ON true
    WHERE 
        p.marketplace = 'SHOPEE'
        AND p.created_at >= pdt.start_date
        AND p.created_at < pdt.end_date -- Mengambil data hingga akhir hari end_date
        AND p.toko_id = 232
        AND p.status NOT IN ('BARU', 'DIBATALKAN', 'GAGAL_KIRIM', 'DIKEMBALIKAN') -- Filter status pesanan yang valid
    GROUP BY p.toko_id
),

gt_manual AS (
    SELECT 
    	COUNT(p.id) AS id_order,
        p.toko_id AS toko,
        SUM(pphs.escrow_amount) * 100.0 / 111.0 AS total_omni,
        SUM(pphs.order_selling_price - pphs.voucher_from_seller) * 100.0 / 111.0 AS total_fat
    FROM pesanan p
    JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
    JOIN toko t ON p.toko_id = t.id
    JOIN param_dates pdt ON true
    WHERE 
        p.marketplace = 'MANUAL'
        AND p.toko_id = 299
        AND p.created_at >=  pdt.start_date
        AND p.created_at <  pdt.end_date
        AND p.toko_id NOT IN (345,151)
        AND p.status NOT IN ('BARU', 'DIKEMBALIKAN', 'DIBATALKAN', 'GAGAL_KIRIM')
        AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
        AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE%' AND t.nama = 'TOKO RIVA')
    GROUP BY p.toko_id
),

gt_tiktok AS (
  WITH per_pesanan AS (
      SELECT
          p.id AS order_id,
          p.toko_id AS toko,
          MAX(CASE
              WHEN pds.nama ILIKE '%Vitabumin Madu 130%' OR pds.nama ILIKE '%Paramorina%' OR pds.nama ILIKE '%Yayle%' OR pds.nama ILIKE '%Cessa%' THEN
                  (ppht.original_total_product_price - ppht.seller_discount)*(1 - 0.1425)*100/111
              WHEN pds.nama ILIKE '%Vitabumin Madu 60%' OR pds.nama ILIKE '%Protabumin%' THEN
                  (ppht.original_total_product_price - ppht.seller_discount)*(1 - 0.16)*100/111
              WHEN pds.nama ILIKE '%Habbie%' THEN
                  (ppht.original_total_product_price - ppht.seller_discount)*(1 - 0.165)*100/111
              ELSE 0
          END) AS total_omni,
          ROUND((ppht.original_total_product_price - ppht.seller_discount)::NUMERIC*100/111, 2) AS total_fat
      FROM pesanan p
      JOIN pesanan_pembentuk_harga_tiktok_shop ppht ON p.id = ppht.pesanan_id
      JOIN pesanan_detail pd ON p.id = pd.pesanan_id
      JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
      JOIN param_dates pdt ON true      
      WHERE p.marketplace = 'TIKTOK_SHOP'
      AND p.status NOT IN ('DIBATALKAN','DIKEMBALIKAN','BARU','GAGAL_KIRIM')
      AND p.toko_id = 311
      AND p.created_at >= pdt.start_date
      AND p.created_at < pdt.end_date -- Mengambil data hingga akhir hari end_date
      GROUP BY p.id, p.created_at, ppht.original_total_product_price, ppht.seller_discount, p.toko_id
  )
  SELECT
  	  toko,
      COUNT(order_id) AS id_order,
      ROUND(SUM(total_omni), 2) AS total_omni,
      SUM(total_fat) AS total_fat
  FROM per_pesanan
  GROUP BY toko
),

gt_shopee_last_month AS ( 
    SELECT 
    	COUNT(p.id) as id_order,
        p.toko_id AS toko
    FROM pesanan p
    JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
    JOIN param_dates_last_month pdt ON true
    WHERE 
        p.marketplace = 'SHOPEE'
        AND p.created_at >= pdt.start_date
        AND p.created_at < pdt.end_date
        AND p.toko_id = 232
        AND p.status NOT IN ('BARU', 'DIBATALKAN', 'GAGAL_KIRIM', 'DIKEMBALIKAN')
    GROUP BY p.toko_id
),
gt_manual_last_month AS (
    SELECT 
    	COUNT(p.id) AS id_order,
        p.toko_id AS toko
    FROM pesanan p
    JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
    JOIN toko t ON p.toko_id = t.id
    JOIN param_dates_last_month pdt ON true
    WHERE 
        p.marketplace = 'MANUAL'
        AND p.toko_id = 299
        AND p.created_at >= pdt.start_date
        AND p.created_at < pdt.end_date
        AND p.toko_id NOT IN (345,151)
        AND p.status NOT IN ('BARU', 'DIKEMBALIKAN', 'DIBATALKAN', 'GAGAL_KIRIM')
        AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
        AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE%' AND t.nama = 'TOKO RIVA')
    GROUP BY p.toko_id
),
gt_tiktok_last_month AS (
  WITH per_pesanan AS (
      SELECT
          p.id AS order_id,
          p.toko_id AS toko,
          MAX(CASE
              WHEN pds.nama ILIKE '%Vitabumin Madu 130%' OR pds.nama ILIKE '%Paramorina%' OR pds.nama ILIKE '%Yayle%' OR pds.nama ILIKE '%Cessa%' THEN
                  (ppht.original_total_product_price - ppht.seller_discount)*(1 - 0.1425)*100/111
              WHEN pds.nama ILIKE '%Vitabumin Madu 60%' OR pds.nama ILIKE '%Protabumin%' THEN
                  (ppht.original_total_product_price - ppht.seller_discount)*(1 - 0.16)*100/111
              WHEN pds.nama ILIKE '%Habbie%' THEN
                  (ppht.original_total_product_price - ppht.seller_discount)*(1 - 0.165)*100/111
              ELSE 0
          END) AS total_omni,
          ROUND((ppht.original_total_product_price - ppht.seller_discount)::NUMERIC*100/111, 2) AS total_fat
      FROM pesanan p
      JOIN pesanan_pembentuk_harga_tiktok_shop ppht ON p.id = ppht.pesanan_id
      JOIN pesanan_detail pd ON p.id = pd.pesanan_id
      JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
      JOIN param_dates_last_month pdt ON true      
      WHERE p.marketplace = 'TIKTOK_SHOP'
      AND p.status NOT IN ('DIBATALKAN','DIKEMBALIKAN','BARU','GAGAL_KIRIM')
      AND p.toko_id = 311
      AND p.created_at >= pdt.start_date
      AND p.created_at < pdt.end_date -- Mengambil data hingga akhir hari end_date
      GROUP BY p.id, p.created_at, ppht.original_total_product_price, ppht.seller_discount, p.toko_id
  )
  SELECT
  	  toko,
      COUNT(order_id) AS id_order,
      ROUND(SUM(total_omni), 2) AS total_omni,
      SUM(total_fat) AS total_fat
  FROM per_pesanan
  GROUP BY toko
),

agg AS (
  SELECT
    (SELECT COALESCE(SUM(awareness),0) FROM all_kol)  AS kol_aw,
    (SELECT COALESCE(SUM(interest),0)  FROM all_kol)  AS kol_in,
    (SELECT COALESCE(SUM(desire),0)    FROM all_kol)  AS kol_de,

    (SELECT COALESCE(SUM(awareness),0) FROM all_am)   AS am_aw,
    (SELECT COALESCE(SUM(interest),0)  FROM all_am)   AS am_in,
    (SELECT COALESCE(SUM(desire),0)    FROM all_am)   AS am_de,

    (SELECT COALESCE(SUM(awareness),0) FROM internal) AS int_aw,
    (SELECT COALESCE(SUM(interest),0)  FROM internal) AS int_in,
    (SELECT COALESCE(SUM(desire),0)    FROM internal) AS int_de
),
ord AS (
  SELECT
      (COALESCE((SELECT id_order FROM gt_shopee),0)
    + COALESCE((SELECT id_order FROM gt_manual),0)
    + COALESCE((SELECT id_order FROM gt_tiktok),0)) -
    (COALESCE((SELECT id_order FROM gt_shopee_last_month),0) +
    COALESCE((SELECT id_order FROM gt_manual_last_month),0) +
    COALESCE((SELECT id_order FROM gt_tiktok_last_month),0)) 
    AS total_orders
)
-- Baris 1: nilai absolut
SELECT
  '<span style="color:#4682B4;font-weight:500">' || agg.kol_aw::text || '</span>' AS "KOL A",
  '<span style="color:#4682B4;font-weight:500">' || agg.kol_in::text || '</span>' AS "KOL I",
  '<span style="color:#4682B4;font-weight:500">' || ROUND(agg.kol_de)::text || '</span>' AS "KOL D",

  '<span style="color:#2E8B57;font-weight:500">' || agg.am_aw::text || '</span>' AS "AM A",
  '<span style="color:#2E8B57;font-weight:500">' || agg.am_in::text || '</span>'  AS "AM I",
  '<span style="color:#2E8B57;font-weight:500">' || ROUND(agg.am_de)::text || '</span>' AS "AM D",

  '<span style="color:#8B4513;font-weight:500">' || agg.int_aw::text || '</span>' AS "INTERNAL A",
  '<span style="color:#8B4513;font-weight:500">' || agg.int_in::text || '</span>' AS "INTERNAL I",
  '<span style="color:#8B4513;font-weight:500">' || ROUND(agg.int_de)::text || '</span>' AS "INTERNAL D",

  '<span style="color:#BA55D3;font-weight:500">' || ord.total_orders::text || '</span>' AS "ACTION"
FROM agg CROSS JOIN ord

UNION ALL

-- Baris 2: persentase
SELECT
  NULL::text AS "KOL A",
  '<span style="color:#4682B4;font-weight:400">' || ROUND((agg.kol_in::numeric / NULLIF(agg.kol_aw::numeric,0)) * 100.0, 2)::text || '%</span>' AS "KOL I",
  '<span style="color:#4682B4;font-weight:400">' || ROUND((agg.kol_de::numeric / NULLIF(agg.kol_aw::numeric,0)) * 100.0, 2)::text || '%</span>' AS "KOL D",

  NULL::text AS "AM A",
  '<span style="color:#2E8B57;font-weight:400">' || ROUND((agg.am_in::numeric / NULLIF(agg.am_aw::numeric,0)) * 100.0, 2)::text || '%</span>' AS "AM I",
  '<span style="color:#2E8B57;font-weight:400">' || ROUND((agg.am_de::numeric / NULLIF(agg.am_aw::numeric,0)) * 100.0, 2)::text || '%</span>' AS "AM D",

  NULL::text AS "INTERNAL A",
  '<span style="color:#8B4513;font-weight:400">' || ROUND((agg.int_in::numeric / NULLIF(agg.int_aw::numeric,0)) * 100.0, 2)::text || '%</span>' AS "INTERNAL I",
  '<span style="color:#8B4513;font-weight:400">' || ROUND((agg.int_de::numeric / NULLIF(agg.int_aw::numeric,0)) * 100.0, 2)::text || '%</span>' AS "INTERNAL D",

  '<span style="color:#BA55D3;font-weight:400">' || ROUND(
    (ord.total_orders::numeric / NULLIF((agg.kol_de + agg.am_de + agg.int_de)::numeric, 0)) * 100.0
  , 2)::text || '%</span>' AS "ACTION"
FROM agg CROSS JOIN ord;