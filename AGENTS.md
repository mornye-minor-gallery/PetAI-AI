# PetAI-AI Repository Guidance

- This repository is public and contains only curated AI runtime and research
  code. Do not mirror or merge the private game repository's history into it.
- Do not include personal filesystem paths, private account identifiers, contact
  details, identifiable device addresses, real player data, or secrets in files,
  commit messages, PR text, reviews, comments, or artifacts. Do not publish game
  assets or materials without redistribution rights.
- Commit author and committer names and emails are attribution chosen by each
  contributor; the privacy checker does not screen that metadata.
- Review files, commit messages, PR text, and artifacts before the first push
  of a branch. Install the local hook with `python3 scripts/install_privacy_hook.py`,
  then run `python3 scripts/check_repository_privacy.py --base origin/main` after
  committing. The checker is not an exhaustive privacy or license audit.
- Follow `CONTRIBUTING.md` for the publication boundary and PR procedure.
