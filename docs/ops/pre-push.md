# Pre-push: keep internal review notes out of the public repository

Repository ini publik. Dua direktori berisi catatan kerja internal (audit dan
review rencana), bukan dokumentasi produk:

- `docs/audits/`
- `docs/plan/reviews/`

Keduanya **tidak boleh** ada di riwayat yang diterbitkan. Salinan lokalnya ada di
`.local/audits/` dan `.local/plan-reviews/` (gitignored, tidak pernah di-push).

## Pasang hook

```sh
./task hooks
```

Perintah itu menyetel `core.hooksPath=.githooks` untuk repo ini. Hook bekerja
lokal; CI tidak memakainya, jadi jangan mengandalkannya sebagai satu-satunya
penjaga.

## Apa yang ditolak

`.githooks/pre-push` menolak push bila `HEAD` memuat berkas di dua path itu:

```
pre-push: these paths belong in .local/, not the public repository:
docs/audits/...
```

Kalau itu terjadi, pindahkan berkasnya ke `.local/` dan commit penghapusannya;
jangan melewati hook dengan `--no-verify` kecuali benar-benar tahu alasannya.

## Riwayat

Riwayat yang diterbitkan sudah di-rewrite sekali: kedua direktori dihapus dari
semua ref dengan `git filter-repo --invert-paths`, sehingga
`git log --all -- docs/audits docs/plan/reviews` kosong. Konsekuensinya:

- Semua commit SHA berubah; branch lama juga di-rewrite.
- `origin` dilepas oleh `git filter-repo` lalu dipasang kembali.
- Push pertama setelah rewrite harus `--force-with-lease` (bukan `--force`), dan
  itu **belum dilakukan** — menunggu persetujuan pemilik.
- Bundle sebelum rewrite ada di `.local/backups/pre-rewrite-20261104.bundle`
  bila ada commit lama yang perlu diambil kembali.

## Kenapa bukan dihapus saja

Catatan audit dan review tetap berguna saat mengerjakan ulang bagian yang pernah
dikritik; yang tidak boleh adalah mempublikasikannya. `.local/` menyimpan
salinannya, hook menjaga agar tidak kembali masuk.
