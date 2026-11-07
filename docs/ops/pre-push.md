# Pre-push: keep internal review notes out of the public repository

Repository ini publik. Catatan kerja internal (audit dan review rencana) bukan
dokumentasi produk dan tidak boleh masuk riwayat yang diterbitkan:

- `docs/audit/` — audit bertanggal
- `docs/plan/reviews/` — review rencana (sudah tidak dipakai lagi)

Dua lapis penjaga:

| Lapis | Berkas | Cakupan |
| --- | --- | --- |
| Ignore | `.gitignore` → `docs/audit/` | berlaku di setiap clone dan di CI |
| Hook | `.githooks/pre-push` | hanya mesin yang sudah menjalankan `./task hooks` |

Hook saja tidak cukup: `core.hooksPath` adalah konfigurasi lokal, jadi clone baru
tidak memilikinya. Itulah sebabnya `docs/audit/` sekarang ada di `.gitignore`
yang ter-track. Salinan lokal catatan itu ada di `.local/audits/` dan
`.local/plan-reviews/`.

## Pasang hook

```sh
./task hooks
```

Perintah itu menyetel `core.hooksPath=.githooks` untuk repo ini.

## Apa yang ditolak

`.githooks/pre-push` menolak push bila `HEAD` memuat berkas di path itu:

```
pre-push: these paths belong in .local/, not the public repository:
docs/audit/...
```

Polanya `^docs/(audits?|plan/reviews)/`, jadi `docs/audit/` dan `docs/audits/`
sama-sama tertangkap.

Kalau itu terjadi, pindahkan berkasnya ke `.local/` dan commit penghapusannya;
jangan melewati hook dengan `--no-verify` kecuali benar-benar tahu alasannya.

## Riwayat

Riwayat yang diterbitkan sudah di-rewrite sekali: kedua direktori dihapus dari
semua ref dengan `git filter-repo --invert-paths`, sehingga
`git log --all -- docs/audit docs/audits docs/plan/reviews` kosong. Konsekuensinya:

- Semua commit SHA berubah; branch lama juga di-rewrite.
- `origin` dilepas oleh `git filter-repo` lalu dipasang kembali.
- Bundle sebelum rewrite ada di `.local/backups/` bila ada commit lama yang
  perlu diambil kembali.

## Kenapa bukan dihapus saja

Catatan audit dan review tetap berguna saat mengerjakan ulang bagian yang pernah
dikritik; yang tidak boleh adalah mempublikasikannya. `.local/` menyimpan
salinannya, `.gitignore` dan hook menjaga agar tidak kembali masuk.