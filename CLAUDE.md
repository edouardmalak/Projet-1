# Instructions for Claude — Projet 1

This folder is a git repository synced to GitHub: https://github.com/edouardmalak/Projet-1 (branch `main`). The remote URL in `.git/config` already includes credentials, so `git push` works without prompts.

Pushing to `main` automatically deploys the live site via Cloudflare Pages: https://projet-1-1yi.pages.dev
(The other repo `edouardmalak/projet1` is unused/obsolete.)

## Rule: auto-sync after every change

After creating, editing, or deleting ANY file in this folder, always run (via bash, from the folder's mount path):

```
git add -A && git commit -m "<short description of the change>" && git push
```

Do this at the end of the task without asking the user — they have requested fully automatic sync.

## Notes

- If git fails with a lock error or `rm`/unlink fails with "Operation not permitted", call `mcp__cowork__allow_cowork_file_delete` first, then delete stale `.git/**/*.lock` and `tmp_obj_*` files and retry.
- Never commit `.DS_Store` (already in `.gitignore`).
- If the user says "sync", just run the command above.
