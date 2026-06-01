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
ROW_NUMBER() OVER (
PARTITION BY p.id_marketplace
ORDER BY
CASE
WHEN p.marketplace <> 'MANUAL' AND p.harga > 0 THEN 1
WHEN p.marketplace = 'MANUAL' AND p.harga > 0 THEN 2
ELSE 3
END
) AS urutan
FROM pesanan p
JOIN gudang g ON p.gudang_id = g.id
JOIN toko t ON p.toko_id = t.id
LEFT JOIN valid_marketplace vm ON p.id_marketplace = vm.id_marketplace
WHERE p.created_at >= '2025-05-01'
AND (
(p.marketplace IN ('MANUAL','KIRIMINAJA') AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND p.toko_id = 221)
AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND p.toko_id = 221))
OR (p.marketplace NOT IN ('MANUAL','KIRIMINAJA') AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN'))
)
AND p.toko_id NOT IN (345,151)
) x
WHERE urutan = 1
),

shopee_total AS (
SELECT
TO_CHAR(p.created_at, 'YYYY-MM') AS periode,
SUM(pphs.escrow_amount)*100/111 AS total_omni,
ROUND(SUM(pphs.order_selling_price - pphs.voucher_from_seller)::NUMERIC*100/111,2) AS total_fat
FROM pesanan_bersih p
JOIN pesanan_pembentuk_harga_shopee pphs ON p.id = pphs.pesanan_id
WHERE p.marketplace = 'SHOPEE'
GROUP BY TO_CHAR(p.created_at, 'YYYY-MM')
),

tp_agg AS (
SELECT
order_id,
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
TO_CHAR(p.created_at, 'YYYY-MM') AS periode,
COALESCE(
tp.total_settlement_amount*100/111,
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
FROM pesanan p
JOIN pesanan_pembentuk_harga_tiktok_shop ppht ON p.id = ppht.pesanan_id
JOIN pesanan_detail pd ON p.id = pd.pesanan_id
JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
LEFT JOIN tp_agg tp ON p.id_marketplace = tp.order_id
WHERE p.marketplace = 'TIKTOK_SHOP'
AND p.status NOT IN ('BARU','DIBATALKAN','GAGAL_KIRIM','DIKEMBALIKAN')
AND p.created_at >= '2025-05-01'
GROUP BY
p.id, p.toko_id, ppht.total_amount, tp.total_settlement_amount,
ppht.original_total_product_price, ppht.seller_discount,
periode
)
SELECT
periode,
ROUND(SUM(total_omni), 2) AS total_omni,
ROUND(SUM(total_fat), 2) AS total_fat
FROM pesanan_perhitungan
GROUP BY periode
),

manual_total AS (
SELECT
TO_CHAR(p.created_at, 'YYYY-MM') AS periode,
CASE
WHEN p.customer ->> 'tipe' = 'ENDORSE' THEN 0
ELSE SUM(p.harga) * 100/111
END
AS total_omni,
-- SUM(p.harga) * 100 / 111 AS total_omni,
CASE
WHEN p.customer ->> 'tipe' = 'ENDORSE' THEN 0
ELSE ROUND(SUM(p.harga)::NUMERIC * 100/111, 2)
END
AS total_fat
-- ROUND(SUM(p.harga)::NUMERIC * 100 / 111,2) AS total_fat
FROM pesanan p
JOIN toko t ON p.toko_id = t.id
JOIN users_omni uo ON p.atur_by = uo.id
WHERE
p.marketplace in ('MANUAL','KIRIMINAJA')
AND p.created_at >= '2025-05-01'
AND uo.name NOT IN ('Admin Offline', 'dig1line')
AND p.data ->> 'platform' NOT IN ('TIKTOK_SHOP_MANUAL','SHOPEE_MANUAL')
AND p.status NOT IN ('BARU', 'DIKEMBALIKAN', 'DIBATALKAN', 'GAGAL_KIRIM')
AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND t.nama = 'TOKO RIVA')
AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE%' AND t.nama = 'TOKO RIVA')
GROUP BY p.customer ->> 'tipe', TO_CHAR(p.created_at, 'YYYY-MM')
),

omni_total_semua AS (
SELECT periode, SUM(total_omni) AS total_omni, SUM(total_fat) AS total_fat
FROM (
SELECT periode, total_omni, total_fat FROM shopee_total
UNION ALL
SELECT periode, total_omni, total_fat FROM tiktok_total
UNION ALL
SELECT periode, total_omni, total_fat FROM manual_total
) semua
GROUP BY periode
),

iklan AS (
SELECT periode, SUM(total_biaya) AS total_iklan
FROM (
SELECT TO_CHAR(tanggal, 'YYYY-MM') AS periode, SUM(cost) AS total_biaya
FROM tiktok_ads_manager
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), SUM(biaya_iklan)
FROM tiktok_iklan_gmv_max
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), SUM(biaya_iklan)
FROM tiktok_iklan_booster
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), -SUM(biaya_iklan)
FROM tiktok_proteksi_roas
WHERE tanggal >= '2026-03-24'
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
-- SHOPEE
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), SUM(biaya)
FROM shopee_iklan
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), SUM(biaya)
FROM shopee_iklan_live
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(reporting_starts, 'YYYY-MM'), SUM(amount_spent)
FROM shopee_cpas_internal
GROUP BY TO_CHAR(reporting_starts, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), SUM(pengeluaran_idr)
FROM shopee_cpas_eksternal
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), SUM(pengeluaran_idr)
FROM shopee_cpas_google
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(waktu, 'YYYY-MM'), -SUM(jumlah)
FROM shopee_proteksi_roas
GROUP BY TO_CHAR(waktu, 'YYYY-MM')
UNION ALL
SELECT TO_CHAR(tanggal, 'YYYY-MM'), SUM(biaya)::int
FROM shopee_iklan_toko
GROUP BY TO_CHAR(tanggal, 'YYYY-MM')
) semua_iklan
GROUP BY periode
),

hpp AS (
SELECT
TO_CHAR(p.created_at, 'YYYY-MM') AS periode,
SUM(
CASE
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
ELSE 0
END
)



FROM pesanan p
JOIN pesanan_detail pd ON p.id = pd.pesanan_id
JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
WHERE
p.toko_id NOT IN (151,345)
AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%' AND toko_id = 221)
AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%' AND toko_id = 221)
AND p.status NOT IN ('DIBATALKAN', 'GAGAL_KIRIM', 'BARU','DIKEMBALIKAN')
AND p.created_at >= '2025-05-01'
AND NOT (p.created_at::date = DATE '2025-09-10'
AND UPPER(p.data ->> 'platform') IN ('TIKTOK_SHOP_MANUAL', 'SHOPEE_MANUAL')
)
GROUP BY TO_CHAR(p.created_at, 'YYYY-MM')
),

packing AS (
WITH per_pesanan AS (
SELECT
p.id,
p.created_at::date as tanggal,
DATE_TRUNC('month', p.created_at)::DATE AS bulan_raw,
SUM(pds.qty) AS total_qty,
CASE
-- ATURAN BARU: Mulai April 2026 ke atas
WHEN p.created_at >= '2026-04-01' THEN
CASE
WHEN SUM(pds.qty) >= 1 AND SUM(pds.qty) <= 39 THEN 2000
WHEN SUM(pds.qty) >= 40 THEN 10000
ELSE 0
END
-- ATURAN LAMA: Sebelum April 2026
ELSE
CASE
WHEN SUM(pds.qty) > 0 AND SUM(pds.qty) <= 3 THEN 2000
WHEN SUM(pds.qty) > 3 AND SUM(pds.qty) <= 10 THEN 3000
WHEN SUM(pds.qty) > 10 AND SUM(pds.qty) <= 60 THEN 10000
WHEN SUM(pds.qty) > 60 THEN 12000
ELSE 0
END
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
GROUP BY p.id, DATE_TRUNC('month', p.created_at), p.created_at::date
)
SELECT
TO_CHAR(bulan_raw, 'YYYY-MM') AS periode,
SUM(biaya_packing)
#ERROR!
#ERROR!
#ERROR!
FROM per_pesanan
GROUP BY TO_CHAR(bulan_raw, 'YYYY-MM')
),

beban AS (
SELECT
tahun::text || '-' || LPAD(bulan::text, 2, '0') AS periode,
SUM(nilai_beban) AS total_beban
FROM (
-- Subquery ini memastikan per baris beban hanya dihitung satu kali (menghindari duplikasi join beban_toko)
SELECT
b.id, b.tahun, b.bulan,
CASE
WHEN b.bulan = EXTRACT(MONTH FROM current_date) AND b.tahun = EXTRACT(YEAR FROM current_date) THEN
MAX(b.nilai) * DATE_PART('day', current_date - date_trunc('month', current_date)) /
DATE_PART('day', (date_trunc('month', current_date) + interval '1 month - 1 day'))
ELSE MAX(b.nilai)
END AS nilai_beban
FROM beban b
JOIN beban_toko bt ON b.id = bt.beban_id
GROUP BY b.id, b.tahun, b.bulan
) sub
GROUP BY tahun, bulan
),

ongkir AS (
SELECT
TO_CHAR(p.created_at, 'YYYY-MM') AS periode,
SUM((p.data ->> 'ongkir')::NUMERIC) AS total_ongkir
FROM pesanan p
WHERE
p.created_at >= '2025-05-01'
AND p.status not in ('DIBATALKAN', 'DIKEMBALIKAN', 'GAGAL_KIRIM', 'BARU')
GROUP BY TO_CHAR(p.created_at, 'YYYY-MM')
),

rate_card AS (
SELECT
periode,
SUM(nilai_rc) AS total_ratecard
FROM (
SELECT
TO_CHAR(tanggal, 'YYYY-MM') AS periode,
CASE
-- Jika periode sama dengan bulan ini, hitung pro-rata (berjalan)
WHEN TO_CHAR(tanggal, 'YYYY-MM') = TO_CHAR(CURRENT_DATE, 'YYYY-MM') THEN
nominal * DATE_PART('day', CURRENT_DATE - 1) /
DATE_PART('day', (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month - 1 day'))
-- Jika bulan sudah lewat, ambil nilai penuh
ELSE nominal
END AS nilai_rc
FROM kelontong
) sub
GROUP BY periode
)

SELECT
ots.periode,
ots.total_omni,
ots.total_fat,
COALESCE(o.total_ongkir, 0) AS total_ongkir,
COALESCE(h.total_hpp, 0) AS total_hpp,
COALESCE(b.total_beban, 0) AS total_beban,
COALESCE(i.total_iklan, 0) AS total_iklan,
COALESCE(p.total_packing, 0) AS total_packing,
COALESCE(rc.total_ratecard, 0) AS total_ratecard
FROM omni_total_semua ots
LEFT JOIN hpp h ON h.periode = ots.periode
LEFT JOIN iklan i ON i.periode = ots.periode
LEFT JOIN packing p ON p.periode = ots.periode
LEFT JOIN beban b ON b.periode = ots.periode
LEFT JOIN ongkir o ON o.periode = ots.periode
LEFT JOIN rate_card rc ON rc.periode = ots.periode
ORDER BY ots.periode DESC;
