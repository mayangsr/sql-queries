WITH tp_agg AS (
SELECT order_id, SUM(total_settlement_amount) AS total_settlement_amount
FROM tiktok_pencairan
GROUP BY order_id
),
-- Bagian Omset: Mengikuti logika MAX() dan GROUP BY per ID Pesanan agar tidak double
omni_fat_daily AS (
SELECT
tanggal,
toko_id,
ROUND(SUM(total_omni), 2) AS total_omni,
ROUND(SUM(total_fat), 2) AS total_fat
FROM (
SELECT
p.created_at::date AS tanggal,
p.toko_id,
p.id,
-- OMNI: Pakai pencairan jika ada, kalau tidak pakai fallback per-order (pakai MAX untuk handle join SKU)
COALESCE(
tp.total_settlement_amount*100/111,
MAX(
CASE
WHEN pds.nama ILIKE '%Vitabumin Madu 130%' OR pds.nama ILIKE '%Paramorina%' OR pds.nama ILIKE '%Yayle%' OR pds.nama ILIKE '%Cessa%'
THEN (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.1425) * 100 / 111
WHEN pds.nama ILIKE '%Vitabumin Madu 60%' OR pds.nama ILIKE '%Protabumin%'
THEN (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.16) * 100 / 111
WHEN pds.nama ILIKE '%Habbie%'
THEN (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.165) * 100 / 111
ELSE (ppht.original_total_product_price - ppht.seller_discount) * (1 - 0.1425) * 100 / 111
END
)
) AS total_omni,
-- FAT (DPP)
((ppht.original_total_product_price - ppht.seller_discount)::numeric) * 100 / 111 AS total_fat
FROM pesanan p
JOIN pesanan_pembentuk_harga_tiktok_shop ppht ON ppht.pesanan_id = p.id
JOIN pesanan_detail pd ON pd.pesanan_id = p.id
JOIN pesanan_detail_sku pds ON pds.pesanan_detail_id = pd.id
LEFT JOIN tp_agg tp ON tp.order_id = p.id_marketplace
WHERE p.marketplace = 'TIKTOK_SHOP'
AND p.status NOT IN ('BARU','DIBATALKAN','GAGAL_KIRIM','DIKEMBALIKAN')
GROUP BY
p.created_at::date, p.toko_id, p.id, tp.total_settlement_amount,
ppht.original_total_product_price, ppht.seller_discount
) sub_per_pesanan
GROUP BY tanggal, toko_id
),

-- KHUSUS PACKING (Relasi: p -> pd -> pds)
packing_daily AS (
SELECT
p.created_at::date AS tanggal,
p.toko_id,
SUM(sub.biaya_per_order) AS total_packing
FROM pesanan p
JOIN (
-- Kita ambil created_at juga di sini untuk validasi tanggal aturan
SELECT
pd.pesanan_id,
p_inner.created_at,
SUM(pds.qty) as qty_total,
CASE
-- ATURAN BARU (Mulai April 2026)
WHEN p_inner.created_at >= '2026-04-01' THEN
CASE
WHEN SUM(pds.qty) BETWEEN 1 AND 39 THEN 1000
WHEN SUM(pds.qty) >= 40 THEN 1000
ELSE 0
END
-- ATURAN LAMA (Sebelum April 2026)
ELSE
CASE
WHEN SUM(pds.qty) BETWEEN 1 AND 3 THEN 2000
WHEN SUM(pds.qty) BETWEEN 4 AND 10 THEN 2800
WHEN SUM(pds.qty) BETWEEN 11 AND 60 THEN 3000
WHEN SUM(pds.qty) > 60 THEN 10000
ELSE 0
END
END AS biaya_per_order
FROM pesanan_detail pd
JOIN pesanan_detail_sku pds ON pds.pesanan_detail_id = pd.id
JOIN pesanan p_inner ON pd.pesanan_id = p_inner.id -- Join tambahan untuk cek tanggal
GROUP BY pd.pesanan_id, p_inner.created_at
) sub ON sub.pesanan_id = p.id
WHERE p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
GROUP BY 1, 2
),

-- KHUSUS HPP
hpp_daily AS (
SELECT
p.created_at::date AS tanggal,
p.toko_id,
SUM(CASE
WHEN pds.nama ILIKE '%Habbie Telon%' AND pds.nama ILIKE '%100 ml%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0)
WHEN pds.nama ILIKE '%Paramorina Madu%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0) + (pds.qty::NUMERIC*500)
WHEN pds.nama ILIKE '%Paramorina Tetes%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0) + (pds.qty::NUMERIC*500)
WHEN pds.nama ILIKE '%Vitabumin Madu 130%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0)
WHEN pds.nama ILIKE '%Vitabumin Madu 60%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0)
--WHEN pds.nama ILIKE '%Protabumin Careos%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0) + (pds.qty::NUMERIC*7500)
WHEN pds.nama ILIKE '%Protabumin Careos%' THEN
(pds.qty::NUMERIC * 1000 * 100/111) +
(pds.qty::NUMERIC * (
CASE
WHEN p.created_at >= '2026-01-01' AND p.toko_id = 232 THEN 18000
WHEN p.created_at >= '2026-01-01' THEN 7000
ELSE 7500
END
))

WHEN pds.nama ILIKE '%Protabumin Nutrimom%' THEN
(pds.qty::NUMERIC * 1000 * 100/111) +
(pds.qty::NUMERIC * (
CASE
WHEN p.created_at >= '2026-01-01' AND p.toko_id = 232 THEN 12500
WHEN p.created_at >= '2026-01-01' THEN 5000
ELSE 5500
END
))
--WHEN pds.nama ILIKE '%Protabumin Nutrimom%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0) + (pds.qty::NUMERIC*5500)
WHEN pds.nama ILIKE '%Yayle%' THEN (pds.qty::NUMERIC * 1000)
WHEN pds.nama ILIKE '%Habbie MKP%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0)
WHEN pds.nama ILIKE '%Habbie Telon%' AND pds.nama ILIKE '%60 ml%' THEN (pds.qty::NUMERIC * 1000 * 100.0/111.0)
WHEN pds.nama ILIKE '%GM. TP%' THEN (pds.qty::NUMERIC * 1000 * 100/111)
WHEN pds.nama ILIKE '%Habbie Tester%' THEN (pds.qty::NUMERIC * 1000 * 100/111)
WHEN pds.nama ILIKE '%Gm.Md Banner%' THEN (pds.qty::NUMERIC * 1000 * 100/111)
WHEN pds.nama ILIKE '%Habbie Box Isi 3%' THEN (pds.qty::NUMERIC * 1000 * 100/111)
WHEN pds.nama ILIKE '%Habbie Box Isi 5%' THEN (pds.qty::NUMERIC * 1000 * 100/111)
WHEN pds.nama ILIKE '%Cessa%' THEN (pds.qty::NUMERIC * 1000 * 100/111)
WHEN pds.nama ILIKE '%Lega%' THEN (pds.qty::NUMERIC * 1000 * 100/111)
ELSE 0 END) AS total_hpp
FROM pesanan p
JOIN pesanan_detail pd ON pd.pesanan_id = p.id
JOIN pesanan_detail_sku pds ON pds.pesanan_detail_id = pd.id
WHERE p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
GROUP BY 1, 2
),

-- IKLAN
iklan_daily AS (
SELECT
COALESCE(am.tanggal, gm.tanggal, bo.tanggal, af.tanggal, tpr.tanggal) AS tanggal,
COALESCE(am.toko, gm.toko, bo.toko, af.toko, tpr.toko) AS toko_id,
COALESCE(gm.cost, 0) AS iklan_gmv,
(COALESCE(am.cost, 0) + COALESCE(gm.cost, 0) + COALESCE(bo.cost, 0) + COALESCE(tpr.cost, 0)) AS total_iklan,
COALESCE(af.cost, 0) AS total_affiliator,
COALESCE(tpr.cost, 0) AS proteksi_roas
FROM (SELECT tanggal, toko_id::int as toko, SUM(cost) as cost FROM tiktok_ads_manager GROUP BY 1,2) am
FULL OUTER JOIN (SELECT tanggal, toko_id::int as toko, SUM(biaya_iklan) as cost FROM tiktok_iklan_gmv_max GROUP BY 1,2) gm ON am.toko = gm.toko AND am.tanggal = gm.tanggal
FULL OUTER JOIN (SELECT tanggal, toko_id::int as toko, SUM(biaya_iklan) as cost FROM tiktok_iklan_booster GROUP BY 1,2) bo ON COALESCE(am.toko, gm.toko) = bo.toko AND COALESCE(am.tanggal, gm.tanggal) = bo.tanggal
FULL OUTER JOIN (
SELECT p.created_at::date as tanggal, tp.toko_id::int as toko, (-SUM(tp.affiliate_commission)) + (-SUM(tp.affiliate_shop_ads_commission)) as cost
FROM tiktok_pencairan tp
JOIN pesanan p ON tp.order_id = p.id_marketplace GROUP BY 1,2
) af ON COALESCE(am.toko, gm.toko, bo.toko) = af.toko AND COALESCE(am.tanggal, gm.tanggal, bo.tanggal) = af.tanggal
FULL OUTER JOIN (SELECT tanggal::date as tanggal, toko_id::int as toko, (-SUM(biaya_iklan)) as cost FROM tiktok_proteksi_roas GROUP BY 1,2) tpr
ON COALESCE(am.toko, gm.toko, bo.toko, af.toko) = tpr.toko AND COALESCE(am.tanggal, gm.tanggal, bo.tanggal, af.tanggal) = tpr.tanggal
),

ratecard_bulanan as (
SELECT
toko_id as toko,
SUM(nominal) as total_bulanan,
TO_CHAR(tanggal, 'YYYY-MM') as bulan
FROM kelontong
GROUP BY 1,3
),

ratecard_harian as (
SELECT
toko,
bulan,
total_bulanan / EXTRACT(DAY FROM (DATE_TRUNC('month', (bulan || '-01')::date) + INTERVAL '1 month - 1 day')) AS nilai_harian
FROM ratecard_bulanan
)

SELECT
COALESCE(o.tanggal, i.tanggal, pk.tanggal, hp.tanggal) as tanggal,
COALESCE(o.toko_id, i.toko_id, pk.toko_id, hp.toko_id) as toko_id,
COALESCE(o.total_omni, 0) as total_omni,
COALESCE(o.total_fat, 0) as total_fat,
COALESCE(i.total_iklan, 0) as total_iklan,
COALESCE(i.iklan_gmv, 0) as iklan_gmv,
COALESCE(i.total_affiliator, 0) as total_affiliator,
COALESCE(pk.total_packing, 0) as total_packing,
COALESCE(hp.total_hpp, 0) as total_hpp,
COALESCE(rc.nilai_harian, 0) as ratecard_harian
FROM omni_fat_daily o
FULL OUTER JOIN iklan_daily i ON o.toko_id = i.toko_id AND o.tanggal = i.tanggal
FULL OUTER JOIN packing_daily pk ON COALESCE(o.toko_id, i.toko_id) = pk.toko_id AND COALESCE(o.tanggal, i.tanggal) = pk.tanggal
FULL OUTER JOIN hpp_daily hp ON COALESCE(o.toko_id, i.toko_id, pk.toko_id) = hp.toko_id AND COALESCE(o.tanggal, i.tanggal, pk.tanggal) = hp.tanggal
LEFT JOIN ratecard_harian rc ON
COALESCE(o.toko_id, i.toko_id, pk.toko_id, hp.toko_id) = rc.toko
AND TO_CHAR(COALESCE(o.tanggal, i.tanggal, pk.tanggal, hp.tanggal), 'YYYY-MM') = rc.bulan
ORDER BY tanggal desc
