WITH 
param_dates AS (
  SELECT 
    '{{from}}'::date AS start_date,
    '{{to}}'::date + INTERVAL '1 day' AS end_date
),

total_budget AS (
  SELECT 
    SUM(
      CASE
        WHEN pds.nama ILIKE '%protabumin nutrimom%' THEN pds.qty * 5000
        WHEN pds.nama ILIKE '%protabumin careos%' THEN pds.qty * 7000
        ELSE 0
      END
    ) AS total_budget_marketing
  FROM pesanan p
  JOIN pesanan_detail pd ON p.id = pd.pesanan_id
  JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
  JOIN param_dates pdt ON true
  WHERE 
    p.created_at >= date_trunc('month', pdt.start_date - INTERVAL '1 month')
    AND p.created_at < date_trunc('month', pdt.start_date)
    AND p.status NOT IN ('DIBATALKAN','BARU','DIKEMBALIKAN','GAGAL_KIRIM')
    AND p.marketplace IN ('SHOPEE', 'TIKTOK_SHOP', 'MANUAL')
    AND (
      pds.nama ILIKE '%protabumin nutrimom%' OR 
      pds.nama ILIKE '%protabumin careos%'
    )
    AND (
      p.marketplace != 'MANUAL' 
      OR (
        p.customer ->> 'tipe' <> 'ENDORSE'
        AND p.toko_id NOT IN (345,151)
        AND p.harga > 0
        AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND p.toko_id = 221)
        AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE%' AND p.toko_id = 221)
        AND NOT ((p.customer ->> 'nama') ILIKE '%NAKAMA%' AND p.toko_id = 221)
      )
    )
),

budget_marketing AS (
  SELECT 
      jenis_pengeluaran AS pengeluaran,
      SUM(nominal) as biaya,
      platform
  FROM marketing
  JOIN param_dates pdt ON true
  WHERE tanggal >= pdt.start_date AND tanggal < pdt.end_date
  GROUP BY jenis_pengeluaran, platform
),

sampel_shopee AS (
  SELECT 
    SUM(
      CASE
        WHEN pds.nama ILIKE '%protabumin nutrimom%' THEN pds.qty * 65000
        WHEN pds.nama ILIKE '%protabumin careos%' THEN pds.qty * 85000
        ELSE 0
      END
    ) AS biaya
  FROM pesanan p
  JOIN pesanan_detail pd ON p.id = pd.pesanan_id
  JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
  JOIN param_dates pdt ON true
  WHERE
    p.customer ->> 'tipe' = 'ENDORSE' 
    AND p.toko_id = 221
    AND p.customer ->> 'nama_toko' ILIKE '%PROTABUMIN OFFICIAL SHOP%' 
    AND p.created_at >= pdt.start_date AND p.created_at < pdt.end_date
    AND p.status NOT IN ('BARU', 'DIBATALKAN', 'GAGAL_KIRIM', 'DIKEMBALIKAN') 
),

sampel_tiktok AS (
  SELECT 
    SUM(
      CASE
        WHEN pds.nama ILIKE '%protabumin nutrimom%' THEN pds.qty * 65000
        WHEN pds.nama ILIKE '%protabumin careos%' THEN pds.qty * 85000
        ELSE 0
      END
    ) AS biaya
  FROM pesanan p
  JOIN pesanan_detail pd ON p.id = pd.pesanan_id
  JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
  JOIN param_dates pdt ON true
  WHERE
    (
    p.toko_id = 363
    OR (p.toko_id = 221 AND p.customer ->> 'nama_toko' ILIKE '%protabuminofficial%')
    )
    AND p.created_at >= pdt.start_date AND p.created_at < pdt.end_date
    AND p.status NOT IN ('BARU', 'DIBATALKAN', 'GAGAL_KIRIM', 'DIKEMBALIKAN') 
),

facebook_data AS (
  SELECT 
    'IKLAN FACEBOOK' AS pengeluaran,
    SUM(fb.jumlah_yang_dibelanjakan)::numeric AS shopee,
    0::numeric AS tiktok,
    SUM(fb.jumlah_yang_dibelanjakan)::numeric AS total
  FROM facebook_iklan fb
  JOIN param_dates pdt ON true
  WHERE fb.awal_pelaporan >= pdt.start_date 
    AND fb.awal_pelaporan < pdt.end_date
    AND fb.imported_by = 7
    AND fb.toko_id = 299
),

jenis_list AS (
  SELECT * FROM (
    VALUES 
      ('AM'),
      ('KOL'),
      ('EVENT'),
      ('PROMOSI'),
      ('SAMPEL'),
      ('IKLAN FACEBOOK')
  ) AS j(pengeluaran)
),

gabungan AS (
  SELECT 
    pengeluaran,
    SUM(biaya) FILTER (WHERE platform = 'SHOPEE') AS shopee,
    SUM(biaya) FILTER (WHERE platform = 'TIKTOK_SHOP') AS tiktok,
    SUM(biaya) AS total
  FROM budget_marketing
  GROUP BY pengeluaran

  UNION ALL

  SELECT 
    'SAMPEL' AS pengeluaran,
    COALESCE(s.biaya, 0),
    COALESCE(t.biaya, 0),
    COALESCE(s.biaya, 0) + COALESCE(t.biaya, 0)
  FROM sampel_shopee s
  FULL OUTER JOIN sampel_tiktok t ON true

  UNION ALL

  SELECT * FROM facebook_data
),

final_display AS (
SELECT 
  j.pengeluaran AS "PENGELUARAN",
  'Rp ' || REPLACE(TO_CHAR(COALESCE(g.shopee, 0), 'FM999G999G999'), ',', '.') AS "SHOPEE",
  'Rp ' || REPLACE(TO_CHAR(COALESCE(g.tiktok, 0), 'FM999G999G999'), ',', '.') AS "TIKTOK",
  'Rp ' || REPLACE(TO_CHAR(COALESCE(g.total, 0), 'FM999G999G999'), ',', '.') AS "TOTAL",
  CASE 
  WHEN (SELECT total_budget_marketing FROM total_budget) = 0 THEN 
    '<div style="background:#eee;width:100px;height:14px;border-radius:6px;"></div>'
  ELSE 
    '<div style="background:#eee;width:100px;height:14px;border-radius:6px;position:relative;overflow:hidden;">
       <div style="width:' || ROUND(100.0 * COALESCE(g.total, 0) / (SELECT total_budget_marketing FROM total_budget), 1) || 
       '%;background:#28a745;height:100%;border-radius:6px 0 0 6px;"></div>
       <div style="position:absolute;top:0;left:0;width:100%;text-align:center;font-size:11px;line-height:14px;font-weight:500;color:#333333;">' 
       || ROUND(100.0 * COALESCE(g.total, 0) / (SELECT total_budget_marketing FROM total_budget), 1) || '%</div>
     </div>'
END AS "% TOTAL"

FROM jenis_list j
LEFT JOIN gabungan g ON j.pengeluaran = g.pengeluaran
ORDER BY j.pengeluaran
)

SELECT * FROM final_display

UNION ALL

SELECT 
  '<b>TOTAL SEMUA</b>' AS "PENGELUARAN",
  '<b>Rp ' || REPLACE(TO_CHAR(SUM(COALESCE(g.shopee, 0)), 'FM999G999G999'), ',', '.') || '</b>' AS "SHOPEE",
  '<b>Rp ' || REPLACE(TO_CHAR(SUM(COALESCE(g.tiktok, 0)), 'FM999G999G999'), ',', '.') || '</b>' AS "TIKTOK",
  '<b>Rp ' || REPLACE(TO_CHAR(SUM(COALESCE(g.total, 0)), 'FM999G999G999'), ',', '.') || '</b>' AS "TOTAL",
  CASE 
  WHEN (SELECT total_budget_marketing FROM total_budget) = 0 THEN 
    '<div style="background:#eee;width:100px;height:14px;border-radius:6px;"></div>'
  ELSE 
    '<div style="background:#eee;width:100px;height:14px;border-radius:6px;position:relative;overflow:hidden;">
       <div style="width:' || ROUND(100.0 * SUM(COALESCE(g.total, 0)) / (SELECT total_budget_marketing FROM total_budget), 1) || '%;background:#51C4D3;height:100%;"></div>
       <div style="position:absolute;top:0;left:0;width:100%;text-align:center;font-size:11px;font-weight:500;color:#333333;">' 
       || ROUND(100.0 * SUM(COALESCE(g.total, 0)) / (SELECT total_budget_marketing FROM total_budget), 1) || '%</div>
     </div>'
END AS "% TOTAL"

  --'<b>' || ROUND(100.0 * SUM(COALESCE(g.total, 0)) / NULLIF((SELECT total_budget_marketing FROM total_budget), 0), 2) || '%</b>' AS "% TOTAL"
FROM gabungan g
WHERE g.pengeluaran IN (SELECT pengeluaran FROM jenis_list)