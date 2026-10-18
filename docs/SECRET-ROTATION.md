# Rotasi Kredensial & Kesiapan Rahasia

Dokumen ini mencatat kredensial yang pernah ter-commit, mana yang masih perlu dirotasi, dan cara
melakukannya. Diperiksa terakhir: 18 Oktober 2026.

**Cara memeriksa ulang secara otomatis:**

```bash
./scripts/scan-secrets.sh
```

Skrip itu memeriksa 4 repo, hanya file yang dilacak git, dan mengembalikan exit code 1 kalau ada
temuan. Nilai yang ditemukan selalu dipotong sebelum ditampilkan.

---

## 1. Ringkasan temuan

Beberapa nilai pernah masuk ke `dev/*.env.example` dan `prod/*.env.example`, jadi nilai-nilai itu
**ada di riwayat git** dan harus dianggap bocor.

| Kredensial | Bocor di | Yang dipakai server sekarang | Tindakan |
| :--- | :--- | :--- | :--- |
| `WA_CLOUD_API_TOKEN` (`EAA_PR…`, 25 char) | `prod/main.env.example` (riwayat) | Dev memakai nilai lain (placeholder 12 char) | **Rotasi** — token asli pernah ter-commit. Rotasi juga di produksi nanti. |
| `FIREBASE_PRIVATE_KEY` | `prod/main.env.example` (riwayat) | Kunci nyata 1728 char ada di server (`.env`, chmod 600) | **Periksa & rotasi.** Nilai di template terpotong, tapi kalau kunci yang dipakai sekarang adalah kunci yang sama, ia harus dibuat ulang. |
| `BITESHIP_WEBHOOK_SECRET` (`bitesh…`, 27 char) | `dev/shipment.env.example`, `prod/*.env.example` | Dev memakai nilai berbeda (34 char) | **Rotasi** untuk prod sebelum rilis; dev sudah bukan nilai yang bocor. |
| `IPAYMU_API_KEY` (`PRODUC…`, 30 char) | `prod/main.env.example` (riwayat) | Dev memakai kunci sandbox (43 char) | **Belum terpakai** (produksi belum ada). Pakai kunci baru saat menyiapkan produksi. |
| `JWT_SECRET` | Template (placeholder), **dan server dev memakai nilai lemah** `asdsda…` (31 char) | Sama di dev | **Wajib ganti.** Rahasia JWT yang bisa ditebak membuat siapa pun bisa memalsukan token. |
| `JWT_REFRESH_SECRET` | Template (placeholder) | — | Ganti bersamaan dengan `JWT_SECRET` saat menyiapkan produksi. |
| `SHIPMENT_INTERNAL_TOKEN`, `KIOSK_HMAC_SECRET`, `RESEND_API_KEY`, `CLOUDFLARE_API_TOKEN`, `R2_SECRET_ACCESS_KEY`, `SMTP_PASS` | Template berisi placeholder (`your_…`, `generated_…`, kosong) | Nilai asli berbeda | Tidak perlu rotasi karena hanya placeholder yang ter-commit. |

## 2. Temuan keamanan tambahan (bukan soal rotasi)

- **Handshake kiosk tidak memverifikasi tanda tangan.** `authService.kioskHandshake()` hanya
  memeriksa `deviceId` terdaftar dan aktif; parameter `hmacSignature` tidak pernah dicek. Artinya
  siapa pun yang tahu `deviceId` bisa mendapatkan status AUTHORIZED. `KIOSK_HMAC_SECRET` belum
  dipakai untuk apa pun, jadi menggantinya tidak menutup celah ini.
- **`JWT_SECRET` dev lemah** (`asdsda…`). Selama produksi belum ada, pastikan produksi memakai
  rahasia hasil generate, bukan nilai ini.

## 3. Cara rotasi

Aturan umum: **generate nilai baru → pasang di dua sisi (penyedia + `.env`) → deploy → verifikasi →
baru cabut nilai lama.** Urutan ini menghindari jendela waktu di mana layanan menolak trafik yang sah.

Semua `.env` di server memiliki permission `600` dan tidak dilacak git. Untuk mengubah nilai di dev,
sunting `dev/main.env` / `dev/shipment.env` di laptop, lalu `./scripts/deploy.sh dev` (deploy
mengunggah `.env` tersebut ke server).

### 3.1 `JWT_SECRET` dan `JWT_REFRESH_SECRET`

```bash
openssl rand -base64 48
```
1. Pasang di `dev/main.env` (dan `prod/main.env` saat rilis).
2. Deploy.
3. **Konsekuensi:** semua sesi aktif menjadi tidak valid, pengguna harus login ulang. Lakukan pada
   jam sepi.
4. Verifikasi: login pelanggan lewat storefront mengembalikan token, lalu buka `/akun`.

### 3.2 `BITESHIP_WEBHOOK_SECRET`

1. Ubah rahasia di dashboard Biteship (URL webhook atau header).
2. Nilai ini harus **sama** di dua tempat: `dev/main.env` dan `dev/shipment.env`.
3. Deploy, lalu pastikan webhook dengan header lama ditolak (401) dan yang baru diterima (200).

### 3.3 `WA_CLOUD_API_TOKEN`

1. Buat token baru untuk System User di Meta Business Suite, lalu cabut yang lama.
2. Pasang di `dev/main.env`, deploy.
3. Verifikasi: kirim satu notifikasi uji lewat antrean WhatsApp dan pastikan terkirim.

### 3.4 `FIREBASE_PRIVATE_KEY`

1. Google Cloud Console → IAM → Service Accounts → kunci baru, unduh JSON.
2. Cabut kunci lama **setelah** kunci baru terbukti jalan.
3. Salin `private_key` ke `FIREBASE_PRIVATE_KEY` (pertahankan `\n` sebagai teks, bukan baris baru).
4. Deploy, lalu verifikasi unggah media:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST \
     -H "Authorization: Bearer <token staf>" -H 'Content-Type: application/json' \
     -d '{"folder":"verifikasi","fileName":"uji.jpg","contentType":"image/jpeg"}' \
     https://dev-api.aprileyewear.com/api/v1/uploads/signed-url
   ```
   `201` berarti kunci baru bekerja.

### 3.5 `SHIPMENT_INTERNAL_TOKEN`

Rahasia bersama antara main service dan shipment service (main memakainya untuk memanggil shipment).
Generate dengan `openssl rand -hex 32`, pasang di **kedua** `.env`, deploy, lalu pastikan endpoint
internal masih berjalan (rates/area).

## 4. Kredensial produksi iPaymu (checklist sebelum rilis)

Kode sudah menolak jalan tanpa kredensial di produksi (`createPayment` melempar error yang jelas),
jadi ini hanya perlu diisi sekali saat menyiapkan produksi:

| Variabel | Nilai |
| :--- | :--- |
| `IPAYMU_VA` | Virtual Account produksi dari dashboard iPaymu |
| `IPAYMU_API_KEY` | API key produksi (bukan yang ter-commit) |
| `IPAYMU_ENV` | `production` |
| `IPAYMU_BASE_URL` | `https://my.ipaymu.com/api/v2` |
| `IPAYMU_CALLBACK_URL` | `https://api.aprileyewear.com/api/v1/payments/ipaymu/callback` |

Verifikasi: lakukan satu transaksi bernilai kecil, pastikan callback masuk (pesanan berubah `PAID`)
dan stok terkunci; lalu kembalikan dana lewat dashboard iPaymu.

## 5. Tentang menghapus nilai dari riwayat git

Menghapus nilai dari HEAD saja **tidak cukup** — nilai itu tetap ada di objek git dan bisa dibaca
siapa pun yang punya akses repo. Pilihan:

- **Rotasi (wajib, cukup untuk keamanan).** Begitu nilainya tidak berlaku lagi, isi riwayat menjadi
  tidak berguna. Ini langkah utama dan tidak merusak apa pun.
- **Tulis ulang riwayat (opsional).** `git filter-repo` atau BFG untuk menghapus nilainya dari semua
  commit. Ini **mengubah hash commit** dan memaksa semua orang clone ulang, jadi hanya lakukan kalau
  repo-nya sensitif atau nilainya tidak bisa dirotasi. Perlu keputusan eksplisit, bukan langkah rutin.

Karena nilainya bocor lewat file contoh, kebiasaan yang mencegah terulang: `.env.example` **hanya**
berisi placeholder (`your_…`, kosong), dan nilai asli selalu di `.env` yang di-ignore
(`.gitignore` sudah memuat `**/*.env` di repo infra).
