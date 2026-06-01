WITH omni_fat AS (
WITH pphs_per_order AS (
SELECT
pphs.pesanan_id,
SUM(pphs.escrow_amount) AS escrow_sum,
SUM(pphs.order_selling_price - pphs.voucher_from_seller) AS fat_sum
FROM pesanan_pembentuk_harga_shopee pphs
GROUP BY pphs.pesanan_id
)
SELECT
p.toko_id AS toko,
DATE_TRUNC('day', p.created_at) AS tanggal, -- Tambahkan kolom tanggal untuk mempermudah filter di MV
SUM(pp.escrow_sum) * 100.0 / 111.0 AS total_omni,
SUM(pp.fat_sum) * 100.0 / 111.0 AS total_fat
FROM pesanan p
JOIN pphs_per_order pp ON pp.pesanan_id = p.id
WHERE p.marketplace = 'SHOPEE'
AND p.status NOT IN ('BARU','DIBATALKAN','GAGAL_KIRIM','DIKEMBALIKAN')
GROUP BY p.toko_id, DATE_TRUNC('day', p.created_at)
),

-- === BEBAN (Affiliator, Content Creator, Live) ===
beban AS (
-- Karena beban dihitung per bulan, MV akan menyimpan beban bulanan per toko
-- dan kalkulasi pro-rata akan dilakukan saat men-query MV
WITH beban_per_bulan AS (
SELECT
b.import_id,
bt.toko_id,
b.jenis,
b.tahun,
b.bulan,
SUM(b.nilai) AS nilai_bulanan_total_import
FROM beban_toko bt
JOIN beban b ON bt.beban_id = b.id
GROUP BY b.import_id, bt.toko_id, b.jenis, b.tahun, b.bulan
),
jumlah_pesanan_per_import AS (
SELECT
b.import_id,
b.jenis,
EXTRACT(YEAR FROM p.created_at) AS tahun,
EXTRACT(MONTH FROM p.created_at) AS bulan,
COUNT(DISTINCT p.id) AS jumlah_pesanan_semua_toko
FROM pesanan p
JOIN beban_toko bt ON p.toko_id = bt.toko_id
JOIN beban b ON bt.beban_id = b.id
WHERE p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
-- AND p.marketplace = 'SHOPEE' -- Tambahkan filter marketplace
GROUP BY b.import_id, b.jenis, EXTRACT(YEAR FROM p.created_at), EXTRACT(MONTH FROM p.created_at)
),
jumlah_pesanan_toko_per_bulan AS (
SELECT
b.import_id,
bt.toko_id,
b.jenis,
EXTRACT(YEAR FROM p.created_at) AS tahun,
EXTRACT(MONTH FROM p.created_at) AS bulan,
COUNT(DISTINCT p.id) AS jumlah_pesanan_toko_ini
FROM pesanan p
JOIN beban_toko bt ON p.toko_id = bt.toko_id
JOIN beban b ON bt.beban_id = b.id
WHERE p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
AND p.marketplace = 'SHOPEE'
GROUP BY b.import_id, bt.toko_id, b.jenis, EXTRACT(YEAR FROM p.created_at), EXTRACT(MONTH FROM p.created_at)
),
beban_terdistribusi_bulanan AS (
-- Distribusikan beban bulanan berdasarkan proporsi pesanan toko
SELECT
t.toko_id,
t.jenis,
t.tahun,
t.bulan,
-- Asumsi MV hanya menghitung bagian proporsional, dan proporsi hari dihitung di SELECT akhir
ROUND((t.jumlah_pesanan_toko_ini::NUMERIC / NULLIF(s.jumlah_pesanan_semua_toko, 0))
* bpb.nilai_bulanan_total_import, 2) AS nilai_beban_bulanan_proporsional
FROM jumlah_pesanan_toko_per_bulan t
JOIN jumlah_pesanan_per_import s
ON s.import_id = t.import_id AND s.jenis = t.jenis AND s.tahun = t.tahun AND s.bulan = t.bulan
JOIN beban_per_bulan bpb
ON bpb.import_id = t.import_id AND bpb.toko_id = t.toko_id AND bpb.jenis = t.jenis AND bpb.tahun = t.tahun AND bpb.bulan = t.bulan
WHERE t.jumlah_pesanan_toko_ini IS NOT NULL AND bpb.toko_id IS NOT NULL
)
SELECT
toko_id AS toko,
tahun,
bulan,
SUM(nilai_beban_bulanan_proporsional) FILTER (WHERE jenis = 'AFFILIATOR') AS beban_am_bulanan,
SUM(nilai_beban_bulanan_proporsional) FILTER (WHERE jenis = 'CONTENT_CREATOR') AS beban_cc_bulanan,
SUM(nilai_beban_bulanan_proporsional) FILTER (WHERE jenis = 'LIVE') AS beban_live_bulanan
FROM beban_terdistribusi_bulanan
GROUP BY toko_id, tahun, bulan
),

-- === IKLAN ===
perhitungan_iklan AS (
SELECT toko, tanggal, SUM(total_biaya) AS total_iklan
FROM (
SELECT toko_id AS toko, tanggal, SUM(biaya) AS total_biaya FROM shopee_iklan GROUP BY 1, 2
UNION ALL
SELECT toko_id AS toko, tanggal, SUM(biaya) AS total_biaya FROM shopee_iklan_live GROUP BY 1, 2
UNION ALL
SELECT toko_id AS toko, reporting_starts AS tanggal, SUM(amount_spent) AS total_biaya FROM shopee_cpas_internal GROUP BY 1, 2
UNION ALL
SELECT toko_id AS toko, tanggal, SUM(pengeluaran_idr) AS total_biaya FROM shopee_cpas_eksternal GROUP BY 1, 2
UNION ALL
SELECT toko_id AS toko, tanggal, SUM(pengeluaran_idr) AS total_biaya FROM shopee_cpas_google GROUP BY 1, 2
UNION ALL
SELECT spr.toko_id AS toko, spr.waktu::date AS tanggal, SUM(-spr.jumlah) AS total_biaya FROM shopee_proteksi_roas spr GROUP BY 1, 2
UNION ALL
SELECT toko_id AS toko, tanggal, SUM(biaya)::int AS total_biaya FROM shopee_iklan_toko GROUP BY 1, 2
) sub_iklan
GROUP BY toko, tanggal
),
affiliate AS (
SELECT
p.toko_id AS toko,
p.created_at::date AS tanggal,
SUM(pphs.order_ams_commission_fee) AS total_aff
FROM pesanan_pembentuk_harga_shopee pphs
JOIN pesanan p ON pphs.pesanan_id = p.id
GROUP BY p.toko_id, p.created_at::date
),

-- Cara memanggilnya agar jadi satu baris per toko per tanggal:
iklan_harian AS (
SELECT
COALESCE(i.toko, a.toko) AS toko,
COALESCE(i.tanggal, a.tanggal) AS tanggal,
COALESCE(i.total_iklan, 0) AS total_iklan,
COALESCE(a.total_aff, 0) AS total_aff
FROM perhitungan_iklan i
FULL OUTER JOIN affiliate a ON i.toko = a.toko AND i.tanggal = a.tanggal
),

-- === PACKING ===
packing AS (
WITH per_pesanan AS (
SELECT
p.id,
p.toko_id AS toko,
p.created_at::date AS tanggal,
SUM(pds.qty) AS total_qty,
CASE
-- ATURAN BARU: Mulai April 2026 ke atas
WHEN p.created_at >= '2026-04-01' THEN
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
END AS biaya_packing
FROM pesanan p
JOIN pesanan_detail pd ON p.id = pd.pesanan_id
JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
WHERE (
(p.marketplace = 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
AND NOT ((p.customer ->> 'nama') ILIKE '%GUDANG%')
AND NOT ((p.customer ->> 'nama') ILIKE '%SHOPEE KONSI%')
)
OR (p.marketplace <> 'MANUAL' AND p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN'))
)
GROUP BY p.id, p.toko_id, p.created_at::date
)
SELECT toko, tanggal, SUM(biaya_packing) AS total_packing
FROM per_pesanan
GROUP BY toko, tanggal
),

-- === HPP (Harga Pokok Penjualan) ===
hpp AS (
SELECT
p.toko_id AS toko,
p.created_at::date AS tanggal,
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
) AS total_hpp
FROM pesanan p
JOIN pesanan_detail pd ON p.id = pd.pesanan_id
JOIN pesanan_detail_sku pds ON pd.id = pds.pesanan_detail_id
WHERE p.status NOT IN ('DIBATALKAN','GAGAL_KIRIM','BARU','DIKEMBALIKAN')
GROUP BY p.toko_id, p.created_at::date
),

-- === GABUNG SEMUA TOKO DAN TANGGAL YANG PUNYA DATA DI SALAH SATU CTE ===
all_toko_harian AS (
SELECT toko, tanggal FROM omni_fat
UNION
SELECT toko, tanggal FROM iklan_harian
UNION
SELECT toko, tanggal FROM packing
UNION
SELECT toko, tanggal FROM hpp
)

-- === FINAL OUTPUT DENGAN DATA HARIAN (belum agregasi) ===
SELECT
ath.toko,
ath.tanggal,
EXTRACT(YEAR FROM ath.tanggal) AS tahun,
EXTRACT(MONTH FROM ath.tanggal) AS bulan,
COALESCE(o.total_omni, 0) AS omset,
COALESCE(o.total_fat, 0) AS omset_fat,
COALESCE(pc.total_packing, 0) AS packing,
COALESCE(i.total_iklan, 0) AS iklan,
COALESCE(i.total_aff, 0) AS affiliator,
COALESCE(h.total_hpp, 0) AS hpp,
b.beban_am_bulanan,
b.beban_cc_bulanan,
b.beban_live_bulanan,
t.nama AS nama_toko -- simpan nama toko
FROM all_toko_harian ath
LEFT JOIN omni_fat o ON ath.toko = o.toko AND ath.tanggal = o.tanggal
LEFT JOIN iklan_harian i ON ath.toko = i.toko AND ath.tanggal = i.tanggal
LEFT JOIN packing pc ON ath.toko = pc.toko AND ath.tanggal = pc.tanggal
LEFT JOIN hpp h ON ath.toko = h.toko AND ath.tanggal = h.tanggal
LEFT JOIN beban b ON ath.toko = b.toko AND EXTRACT(YEAR FROM ath.tanggal) = b.tahun AND EXTRACT(MONTH FROM ath.tanggal) = b.bulan
JOIN toko t ON t.id = ath.toko
WHERE COALESCE(o.total_omni, 0) > 0
