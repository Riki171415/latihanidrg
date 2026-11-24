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

Pendaftaran meminta nama lengkap, email, username, password, nomor telepon, dan asal instansi. Setelah berhasil mendaftar, peserta langsung masuk tanpa konfirmasi email. Login menggunakan email dan password. Username merupakan identitas peserta pada rekap. Password dikelola Supabase Auth dan tidak dimasukkan ke tabel profil atau draf aplikasi.

Draf disimpan otomatis, dengan antrean penyimpanan dan pemeriksaan versi agar perubahan dari dua perangkat tidak saling menimpa tanpa pemberitahuan. Saat jaringan gagal, jawaban yang belum terkirim ditahan di cache perangkat menurut ID akun dan dapat disimpan ulang. Nilai resmi dihitung di database dari bank soal versi terkait, bukan dari skor yang dikirim browser.

Sebelum pengiriman, peserta bebas mengubah jawaban. Setelah paket dikirim, peserta dapat membuka **satu kali tahap revisi**, mengubah jawaban, lalu mengirim ulang. Setelah pengiriman revisi, paket dikunci. Riwayat menyimpan jawaban dan nilai awal serta revisi secara terpisah. Pembatasan ini diperiksa oleh server; admin tidak dapat memakai fungsi peserta untuk mengganti jawaban orang lain.

Peserta hanya dapat membaca data sendiri. Admin ditentukan oleh daftar email yang dikelola pemilik proyek dalam `idrg_private.admin_allowlist` atau peran internal yang dilindungi. Akun harus aktif pada Supabase Auth. Data `user_metadata` tidak memberikan hak admin. Dashboard memiliki pencarian, filter instansi, nilai per materi, progres draf, dan detail jawaban serta riwayat nilai.

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

Tambahkan email admin melalui SQL pemilik proyek menggunakan pola di `supabase/grant-admin.sql`. Berkas `admin.local.sql` tidak masuk Git. Setelah email disetujui, pemilik email mendaftarkan akun lengkap; akses admin muncul saat login. Jangan membagikan password antarpengguna.

Pada Supabase **Authentication → URL Configuration**, gunakan:

- Site URL: `https://latihanidrg.netlify.app`
- Redirect URL: `https://latihanidrg.netlify.app/`

Konfigurasi URL ini diperlukan untuk tautan pemulihan password. Pada Authentication → Sign In / Providers → Email, nonaktifkan **Confirm email**. Pendaftaran langsung memperoleh sesi dan masuk ke ruang latihan tanpa konfirmasi email. Aplikasi memeriksa pengaturan ini sebelum memanggil signup agar tidak mengirim email konfirmasi ketika proyek belum disesuaikan. Pengaturan email/SMTP dan batas pengiriman mengikuti konfigurasi proyek Supabase.

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

## Resume medis simulasi — versi 2026-11-23.4

27 berkas klinis menggunakan resume lengkap: identitas dan waktu pelayanan, anamnesis, riwayat, pemeriksaan fisik/penunjang, diagnosis dokter, perjalanan perawatan dan terapi, laporan tindakan, kondisi akhir, dan tindak lanjut. Berkas pembanding memisahkan setiap pasien dalam episode tersendiri. M2-01 tetap berupa lembar kerja pembacaan kode grouper. Identitas serta data klinis adalah simulasi pembelajaran yang diizinkan penyelenggara, bukan data pasien nyata atau salinan verbatim contoh ICS.

PDF aktif memakai URL dengan versi. Tautan lama di /cases tetap mengarah ke dokumen terbaru; riwayat memakai /cases/archive/2026-11-23.3 dan bank publik tanpa kunci di /banks. Klien terbaru meminta idrg_start_packet_versioned dengan versi eksplisit. Klien yang sudah terbuka tetap memakai fungsi lama dan bank 2026-11-23.3; karena itu flag active bank lama sengaja dipertahankan. Bank baru dapat dikerjakan melalui RPC berversi walaupun active=false.

Jawaban dan nilai terdahulu tidak dipindahkan atau dinilai ulang menggunakan soal baru. Rekap menampilkan hasil/draf versi sebelumnya terpisah; peserta dapat melanjutkan draf lama dengan naskah serta PDF lama. Pembatasan satu revisi berlaku per pengerjaan paket dan versi. Kunci/pembahasan historis tetap dipertahankan di Supabase.

Regenerasi PDF: python scripts/generate_pdfs.py (memerlukan ReportLab, PyMuPDF, serta Arial lokal). Setiap PDF bertanda SIMULASI. Rujukan penelaahan klinis disimpan di docs/clinical-review.md.

## Penyuntingan naskah 2026-11-24.1

Bahasa pertanyaan disederhanakan dan diselaraskan dengan istilah pasien A/B/C pada berkas. Penanda simulasi pada tampilan kasus dan PDF dikeluarkan dari naskah peserta; asal-usul data sebagai kasus buatan tetap dicatat dalam dokumentasi penyusun. Laporan operasi/tindakan mencakup tanggal, diagnosis, indikasi, pelaksana, anestesi, akses, temuan, pelaksanaan, penutupan/hemostasis, spesimen/implan, perdarahan, komplikasi, serta kondisi akhir. Teknik yang sengaja tidak terdokumentasi pada soal klarifikasi tidak direka sebagai temuan pasti.

Rujukan prosedur ditelaah dari Coder’s Desk Reference for ICD-9-CM Procedures (Ingenix/Optum, 2009) pada berkas referensi lokal. Uraian kasus disusun ulang, bukan salinan teks buku. Kunci ORIF humerus diperbaiki menjadi 79.31 berdasarkan klasifikasi prosedur; contoh 79.39 pada satu tabel sumber ICS tidak digunakan sebagai kunci baru. Nilai bank terdahulu tidak diubah. Bank lengkap 2026-11-23.4 kini juga diarsipkan agar riwayat masih dapat dibaca sesuai naskah saat dikerjakan.

## Tata letak PDF — layout-2

Narasi menggunakan perataan justify; label serta isi tabel memakai perataan kiri agar tidak menimbulkan spasi berlebihan. Setiap berkas klinis memiliki tabel dua kolom diagnosis utama/sekunder dan tabel terpisah prosedur utama/sekunder. Nilai kolom mengikuti dokumentasi berkas. Pada kasus audit MB, urutan diagnosis awal yang keliru atau berisi beberapa diagnosis utama tetap dipertahankan untuk ditelaah peserta. Data yang tidak dicantumkan diberi keterangan, tanpa menambahkan kode jawaban pada PDF.

Field formulir terdapat pada chartFields menurut pasien/episode. Catatan diagnosis tidak mengulang seluruh daftar penyakit. Rincian operasi disajikan per paragraf dengan label yang ditebalkan. Tabel diagnosis dan catatannya dikelompokkan agar tidak terpisah saat pergantian halaman. PDF baru memakai subdirektori layout-2; tautan langsung /cases/M…pdf juga diperbarui. Bank pertanyaan, kunci, skor, dan revisi pengerjaan tidak berubah karena pembaruan ini hanya menyusun tampilan berkas.

## Pemuatan akun saat gangguan Data API

Login memuat profil, riwayat pengerjaan, dan hak admin melalui satu RPC baca idrg_load_account setelah identitas diperiksa oleh Supabase Auth. Fungsi menggunakan security invoker, tetap memeriksa UID pemilik, dan tidak memberikan akses anonim. Pengambilan akun dibatasi 10 detik per permintaan dan diulang paling banyak satu kali untuk gangguan sementara.

Jika tetap gagal, sesi autentikasi dipertahankan dan tombol Coba muat akun memuat ulang data tanpa meminta atau mengirim ulang password. Kesalahan autentikasi tetap dibedakan dari gangguan pool/schema cache. Operasi simpan dan kirim jawaban tidak diputar ulang otomatis karena respons gagal tidak memastikan transaksi belum tersimpan. Perbaikan aplikasi mengurangi beban dan memperbaiki pemulihan, tetapi tidak menggantikan pemulihan layanan PostgREST ketika masih mengembalikan PGRST002/PGRST003.
