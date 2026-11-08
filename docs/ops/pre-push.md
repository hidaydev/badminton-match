# Pre-push: keep internal notes out of the public repository

Repository ini publik. Catatan kerja internal (audit dan review rencana) bukan
dokumentasi produk dan tidak boleh masuk riwayat yang diterbitkan. Direktori
`docs/audit/`, `docs/audits/`, dan `docs/plan/reviews/` sudah tidak ada di tree;
penjaganya tetap dipasang untuk catatan yang dibuat lagi nanti.

Dua lapis penjaga:

| Lapis | Berkas | Cakupan |
| --- | --- | --- |
| Ignore | `.gitignore` → `docs/audit/` | berlaku di setiap clone dan di CI |
| Hook | `.githooks/pre-push` | hanya mesin yang sudah menjalankan `./task hooks` |

Hook saja tidak cukup: `core.hooksPath` adalah konfigurasi lokal, jadi clone baru
tidak memilikinya. Itulah sebabnya `docs/audit/` ada di `.gitignore` yang
ter-track. Catatan lokal disimpan di `.local/` (gitignored).

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
jangan lewati hook dengan `--no-verify` kecuali benar-benar tahu alasannya.

## Riwayat

Riwayat yang diterbitkan sudah di-rewrite sekali: kedua direktori dihapus dari
semua ref dengan `git filter-repo --invert-paths`, sehingga
`git log --all -- docs/audit docs/audits docs/plan/reviews` kosong. Semua commit
SHA berubah dan branch lama ikut di-rewrite. Bundle sebelum rewrite tidak lagi
disimpan di mesin ini; ambil dari salinan yang masih memilikinya bila ada commit
lama yang perlu diambil kembali.