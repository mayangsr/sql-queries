WITH 
param_dates AS (
	SELECT
	'2025-06-01'::date AS start_date,
    '2025-12-30'::date + INTERVAL '1 Day' AS end_date
),

orderan_shopee AS (
	SELECT
    	EXTRACT(MONTH FROM p.created_at)::int AS bulan,
    	pds.nama AS produk,
        SUM(pds.qty) as qty,
        SUM(
        	CASE
        		WHEN pds.nama ILIKE '%protabumin nutrimom%' THEN pds.qty * 5000
        		WHEN pds.nama ILIKE '%protabumin careos%' THEN pds.qty * 7000
        		ELSE 0
        	END
        ) AS biaya
	FROM pesanan p
	JOIN pesanan_detail pd ON p.id = pd.pesanan_id
	JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
	JOIN param_dates pdt ON true
	WHERE
		p.marketplace = 'SHOPEE'
		AND p.created_at >= pdt.start_date
		AND p.created_at < pdt.end_date
		AND p.status NOT IN ('BARU', 'DIBATALKAN', 'GAGAL_KIRIM', 'DIKEMBALIKAN') 
	GROUP BY 1, 2
),

orderan_tiktok AS (
	SELECT
    	EXTRACT(MONTH FROM p.created_at)::int AS bulan,
    	pds.nama AS produk,
        SUM(pds.qty) AS qty,
        SUM(
        	CASE
        		WHEN pds.nama ILIKE '%protabumin nutrimom%' THEN pds.qty * 5000
        		WHEN pds.nama ILIKE '%protabumin careos%' THEN pds.qty * 7000
        		ELSE 0
        	END
        ) AS biaya
	FROM pesanan p
	JOIN pesanan_detail pd ON p.id = pd.pesanan_id
	JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
	JOIN param_dates pdt ON true
	WHERE
		p.created_at >= pdt.start_date
		AND p.created_at < pdt.end_date
		AND p.marketplace = 'TIKTOK_SHOP'
		AND p.status NOT IN ('DIBATALKAN','BARU','DIKEMBALIKAN','GAGAL_KIRIM')
	GROUP BY 1, 2
),

orderan_manual AS (
	SELECT
    EXTRACT(MONTH FROM p.created_at)::int AS bulan,
    pds.nama as produk,
    SUM(pds.qty) AS qty,
    SUM(
        CASE
            WHEN pds.nama ILIKE '%protabumin nutrimom%' THEN pds.qty * 5000
            WHEN pds.nama ILIKE '%protabumin careos%' THEN pds.qty * 7000
            ELSE 0
        END
    ) AS biaya
    FROM pesanan p
    JOIN pesanan_detail pd ON p.id = pd.pesanan_id
    JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
    JOIN param_dates pdt ON true
    WHERE
        p.created_at >= pdt.start_date
        AND p.created_at < pdt.end_date
        AND p.marketplace = 'MANUAL'
        AND p.customer ->> 'tipe' <> 'ENDORSE'
        AND p.toko_id NOT IN (345,151)
        AND p.harga > 0
        AND (
            pds.nama ILIKE '%protabumin nutrimom%'
            OR pds.nama ILIKE '%protabumin careos%'
        )
        AND p.status NOT IN ('DIBATALKAN','BARU','DIKEMBALIKAN','GAGAL_KIRIM')
        AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND p.toko_id = 221)
        AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE%' AND p.toko_id = 221)
        --AND NOT ((p.customer ->> 'nama') ILIKE '%NAKAMA%' AND p.toko_id = 221)
        AND NOT (EXTRACT(MONTH FROM p.created_at) = 6 AND (p.customer ->> 'nama') ILIKE '%NAKAMA%')
    GROUP BY bulan, pds.nama
),

gabungan AS (
	SELECT * FROM orderan_shopee
	UNION ALL
	SELECT * FROM orderan_tiktok
    UNION ALL 
    SELECT * FROM orderan_manual
),

rekap AS (
	SELECT
		produk,
		bulan,
        SUM(qty) AS qty,
		SUM(biaya) AS total_biaya
	FROM gabungan
    WHERE produk ILIKE '%protabumin nutrimom%'
		OR produk ILIKE '%protabumin careos%'
	GROUP BY produk, bulan
),
final_result AS (
	SELECT
		produk AS "PRODUK",
		'Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 6 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') AS "JULI",
		'Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 7 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') AS "AGUSTUS",
		'Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 8 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') AS "SEPTEMBER",
		'Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 9 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') AS "OKTOBER",
        'Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 10 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') AS "NOVEMBER",
        'Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 11 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') AS "DESEMBER"
	FROM rekap
	GROUP BY produk

	UNION ALL

	SELECT
		'<b>TOTAL</b>',
		'<b>Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 6 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') || '</b>',
		'<b>Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 7 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') || '</b>',
		'<b>Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 8 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') || '</b>',
		'<b>Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 9 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') || '</b>',
        '<b>Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 10 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') || '</b>',
        '<b>Rp ' || REPLACE(TO_CHAR(SUM(CASE WHEN bulan = 11 THEN total_biaya ELSE 0 END), 'FM999G999G999G999'),',','.') || '</b>'
	FROM rekap
)

SELECT *
FROM final_result
ORDER BY 
	CASE 
		WHEN "PRODUK" = '<b>TOTAL</b>' THEN 1
		ELSE 0 
	END,
	"PRODUK";