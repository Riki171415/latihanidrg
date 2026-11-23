# iDRG Learning

Aplikasi pelatihan pengodean iDRG berbasis ICS 2026. Peserta memiliki akun, membaca PDF kasus, menjawab pilihan A–E, dan menerima nilai per paket. Supabase menyimpan identitas, draf, hasil, dan riwayat revisi. Dashboard admin memuat progres serta rincian jawaban peserta.

## Paket praktik

| Paket | Kasus | Soal |
| --- | ---: | ---: |
| Casemix · Materi 2 | 2 | 8 |
| Pengodean iDRG · Materi 3 | 7 | 28 |
| Materi 4 | 11 | 44 |
| Materi 6 | 8 | 32 |
| Total | 28 | 112 |

Paket Materi 3 mempertahankan ID penyimpanan `2-coding` dan kunci kasus lama untuk kesinambungan data. Nama paket dan nomor berkas yang ditampilkan memakai Materi 3.

## Akun dan hasil

Pendaftaran meminta nama lengkap, email, username, password, nomor telepon, dan asal instansi. Login menggunakan email dan password. Username merupakan identitas peserta pada rekap. Password dikelola Supabase Auth dan tidak dimasukkan ke tabel profil atau draf aplikasi.

Draf disimpan otomatis, dengan antrean penyimpanan dan pemeriksaan versi agar perubahan dari dua perangkat tidak saling menimpa tanpa pemberitahuan. Saat jaringan gagal, jawaban yang belum terkirim ditahan di cache perangkat menurut ID akun dan dapat disimpan ulang. Nilai resmi dihitung di database dari bank soal versi terkait, bukan dari skor yang dikirim browser.

Sebelum pengiriman, peserta bebas mengubah jawaban. Setelah paket dikirim, peserta dapat membuka **satu kali tahap revisi**, mengubah jawaban, lalu mengirim ulang. Setelah pengiriman revisi, paket dikunci. Riwayat menyimpan jawaban dan nilai awal serta revisi secara terpisah. Pembatasan ini diperiksa oleh server; admin tidak dapat memakai fungsi peserta untuk mengganti jawaban orang lain.

Peserta hanya dapat membaca data sendiri. Admin ditentukan oleh daftar email yang dikelola pemilik proyek dalam `idrg_private.admin_allowlist` atau peran internal yang dilindungi. Email akun harus terverifikasi. Data `user_metadata` tidak memberikan hak admin. Dashboard memiliki pencarian, filter instansi, nilai per materi, progres draf, dan detail jawaban serta riwayat nilai.

Hasil versi lama tanpa login tidak diimpor sebagai nilai resmi akun. Cache lama tetap tidak diubah.

## Menjalankan dan menguji

Gunakan Node.js 22 atau lebih baru:

```sh
npm ci
npm test
npm run dev
```

Buka http://127.0.0.1:4173. Port dapat diganti melalui `IDRG_DEV_PORT`. `npm run build` menghasilkan `dist`. Build memvalidasi 28 kasus dan 112 soal, membundel Supabase SDK/PDF.js, dan menghapus kunci jawaban, pembahasan, serta metadata jawaban lama dari payload peserta.

`npm test` menjalankan migrasi dan seed pada PostgreSQL lokal melalui PGlite, lalu memeriksa RLS, isolasi peserta, larangan menaikkan peran lewat metadata, perhitungan nilai, konflik penyimpanan, satu kali revisi, penguncian hasil, dan akses dashboard. Pengujian tidak membuat akun atau data peserta di proyek Supabase produksi.

## Supabase

Konfigurasi publik berada di `src/config.json`. Build dapat menggantinya melalui `SUPABASE_URL` dan `SUPABASE_PUBLISHABLE_KEY`. Hanya publishable key digunakan pada browser. Tidak ada service-role key yang diperlukan oleh frontend.

Migrasi produksi sudah dipasang pada proyek yang dikonfigurasi. Untuk membuat ulang pada proyek kosong, jalankan migrasi di `supabase/migrations` menurut urutan versi, lalu `supabase/seed.sql`; `supabase/setup.sql` merupakan gabungan yang dihasilkan `npm run seed` untuk pemasangan pertama. Jangan menjalankan ulang pembuatan tabel pada proyek yang sudah dipasang.

Tambahkan email admin melalui SQL pemilik proyek menggunakan pola di `supabase/grant-admin.sql`. Berkas `admin.local.sql` tidak masuk Git. Setelah email disetujui, pemilik email mendaftarkan akun lengkap dan memverifikasi emailnya; akses admin muncul saat login. Jangan membagikan password antarpengguna.

Pada Supabase **Authentication → URL Configuration**, gunakan:

- Site URL: `https://latihanidrg.netlify.app`
- Redirect URL: `https://latihanidrg.netlify.app/`

Konfigurasi ini diperlukan agar tautan konfirmasi dan pemulihan password kembali ke situs latihan. Aktifkan konfirmasi email untuk akun baru. Pengaturan email/SMTP dan batas pengiriman mengikuti konfigurasi proyek Supabase.

Tabel publik `idrg_profiles` dan `idrg_attempts` memakai RLS. Tabel jawaban benar, peran, daftar email admin, versi soal, dan riwayat berada dalam schema privat dengan akses langsung ditolak. RPC publik menggunakan security invoker; fungsi privat memeriksa pemilik akun atau admin sebelum mengakses data. RLS privat tanpa kebijakan akses langsung merupakan penolakan akses yang disengaja, bukan izin baca untuk peserta.

Saat mengubah isi pertanyaan atau kunci, buat versi bank baru pada `scripts/seed.mjs` dan metadata sumber. Seed mempertahankan kunci versi terdahulu agar hasil dan riwayat yang sudah dikirim tetap dapat diaudit.

## Deploy Netlify

Repositori: `Riki171415/latihanidrg`. Production branch: `main`. Build command: `npm run build`. Publish directory: `dist`. Node.js: `22`. Pengaturan ada pada `netlify.toml`.

## Dokumen kasus

PDF berada di `public/cases`. Narasi menggunakan data yang tersedia dari sumber ICS; identitas, hasil pemeriksaan, atau tindakan yang tidak tersedia tidak ditambahkan. PDF memisahkan berkas peserta dari kunci dan pembahasan. Untuk menghasilkan ulang dokumen, gunakan Python dengan `reportlab` dan `PyMuPDF`, lalu jalankan:

```sh
python scripts/generate_pdfs.py --font-dir C:/Windows/Fonts
```

Font Arial reguler dan tebal diperlukan pada mesin pembuat PDF. Netlify memakai PDF yang sudah disertakan di repositori.
