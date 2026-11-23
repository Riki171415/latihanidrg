# iDRG Learning

Aplikasi latihan koding iDRG dengan berkas kasus PDF, pilihan A–E, nilai otomatis per paket, dan rekap peserta.

## Paket praktik

| Paket | Kasus | Butir |
| --- | ---: | ---: |
| Casemix Materi 2 | 2 | 8 |
| Pengodean iDRG Materi 2 | 7 | 28 |
| Pengodean iDRG Materi 4 | 11 | 44 |
| Pengodean iDRG Materi 6 | 8 | 32 |
| Total | 28 | 112 |

PDF berada di public/cases. Dokumen merupakan rekonstruksi berkas pembelajaran dari ICS 2026. Data klinis yang belum tersedia pada sumber ditandai dalam dokumen.

## Menjalankan aplikasi

Gunakan Node.js 22 atau lebih baru. Jalankan `npm ci`, lalu `npm run dev` dan buka http://127.0.0.1:4173. Jalankan `npm run build` untuk membangun aplikasi ke folder dist. Build memeriksa PDF, jumlah soal, pilihan, dan kunci. Aplikasi menggunakan HTML, CSS, dan JavaScript. PDF.js dibundel untuk menampilkan PDF langsung di aplikasi.

## Deploy GitHub ke Netlify

[Deploy to Netlify](https://app.netlify.com/start/deploy?repository=https://github.com/kekey135/Soal-latihan-iDRG)

Impor repositori kekey135/Soal-latihan-iDRG melalui Netlify. Pengaturan tersedia di netlify.toml.

| Pengaturan | Nilai |
| --- | --- |
| Production branch | main |
| Base directory | Kosong atau akar repositori |
| Build command | npm run build |
| Publish directory | dist |
| Node.js | 22 |

Setelah repositori dihubungkan, push ke main menjadi sumber pembaruan deployment.

## Data latihan

Nama, draf, dan hasil disimpan dalam browser pada perangkat peserta. Rekap dapat diunduh sebagai CSV atau dicetak ke PDF. Gunakan nama yang sama untuk melanjutkan di perangkat yang sama. Migrasi mempertahankan pemisahan Casemix dan Pengodean iDRG serta posisi jawaban yang sudah tersimpan.

## Berkas utama

- index.html adalah template tampilan.
- src/app.js mengatur alur peserta, penilaian, dan rekap.
- src/styles.css mengatur tampilan responsif.
- src/cases.json berisi narasi, pertanyaan, pilihan, dan pembahasan.
- public/cases berisi 28 PDF kasus.
- scripts/build.mjs memvalidasi dan membangun aplikasi.
- scripts/dev.mjs menjalankan server lokal.
- netlify.toml mengatur build dan publish.
