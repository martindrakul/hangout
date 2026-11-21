# Releasing Hangout

Once this is set up, an update is: edit, add a changelog entry, push a tag. GitHub
builds the zip and uploads it to CurseForge, and the CurseForge app offers the update to
everyone after moderators approve the file.

## One-time setup

### 1. CurseForge project

1. Go to https://authors.curseforge.com, then create a project. Choose World of Warcraft, then Addons.
2. Fill it in from `docs/curseforge-page.md`. Use `hangout-avatar-400.png` as the avatar, and add a screenshot of the Hangout window.
3. Upload `Hangout-v1.1.0.zip` as the first file. Set the release type to **Release** and the game version to **WoW Forever 1.60.1**, and paste the 1.1.0 part of `CHANGELOG.md` as the changelog.
4. Wait for approval. Moderators work 8:00–15:00 CET, every day.
5. Note the **Project ID** from the "About Project" box on your project page.

### 2. GitHub repo

```bash
cd hangout
git init -b main
git add .
git commit -m "Hangout 1.1.0"
gh repo create hangout --public --source . --push
```

Don't tag 1.1.0, because you uploaded it to CurseForge by hand. The first tag you push is the next version.

### 3. Secrets

On GitHub, open the repo's **Settings > Secrets and variables > Actions**:

- **Secrets** tab: add `CF_API_TOKEN`. Create the token at https://authors.curseforge.com/#/settings/api-tokens.
- **Variables** tab: add `CURSEFORGE_PROJECT_ID` with the number from step 1.

## Every update after that

1. Change the code.
2. Add a section at the top of `CHANGELOG.md`, for example `## 1.2.0`.
3. Commit, tag and push:

```bash
git commit -am "Something new"
git tag v1.2.0
git push && git push --tags
```

The **Release** workflow runs the tests, builds `Hangout-v1.2.0.zip`, uploads it to
CurseForge for WoW Forever and attaches it to a GitHub release. Use a tag like
`v1.2.0-beta1` to post a beta instead.

## Testing locally

```bash
lua5.1 tests/sim.lua .
```

This runs four simulated players against a fake server. It covers invites, chunked messages with links,
emotes, players going offline, boss-fight lockdowns, removing and re-inviting someone, and channel cleanup.
