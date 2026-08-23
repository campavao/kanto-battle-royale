// Regenerate site/data/index.json from this repo's latest GitHub release.
//
// gen1recomp's launcher does not read update information out of a mod's
// manifest; it reads an index FEED and matches entries to installed mods by
// id.  So "check for updates" only sees this mod if a feed lists it, and this
// script is what writes that feed.
//
// The launcher resolves an index URL two ways (src/mods/ModIndex.lua):
//
//   https://<owner>.github.io/<repo>/data/index.json          (GitHub Pages)
//   https://raw.githubusercontent.com/<owner>/<repo>/main/site/data/index.json
//
// The second is a fallback for exactly the case where Pages has not been set
// up, which is why the file lives at site/data/index.json on main: committing
// it is enough, with no Pages deploy to wait on.
//
//   node tools/build-index.mjs            # uses the latest release
//   node tools/build-index.mjs v0.2.1     # pins a tag
//
// Needs the `gh` CLI on PATH (it is only used to read public release data).

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const REPO = "campavao/kanto-battle-royale";
const OUT = "site/data/index.json";
const tag = process.argv[2];

function gh(args) {
  return JSON.parse(execFileSync("gh", args, { encoding: "utf8" }));
}

const manifest = JSON.parse(readFileSync("manifest.json", "utf8"));
const release = gh([
  "release", "view", ...(tag ? [tag] : []),
  "--repo", REPO,
  "--json", "tagName,name,publishedAt,isPrerelease,assets",
]);

// the mod zip, not the source tarballs GitHub attaches to every release
const zip = release.assets.find((a) => a.name.endsWith(".zip"));
if (!zip) {
  console.error("no .zip asset on " + release.tagName);
  process.exit(1);
}

const version = release.tagName.replace(/^v/, "");
if (version !== manifest.version) {
  // Worth stopping for: the launcher compares the feed's version against the
  // installed manifest's, so a mismatch here either hides an update or offers
  // one that installs the same build.
  console.error(
    `refusing to publish: release ${release.tagName} vs manifest ${manifest.version}`
  );
  process.exit(1);
}

const doc = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  categories: ["MULTIPLAYER"],
  mods: [
    {
      id: manifest.id,
      name: manifest.name,
      author: "campavao",
      version,
      summary:
        "Last trainer standing, in Kanto. Real-time presence, forced " +
        "face-to-face battles, bots, and a fog that closes on the Town Map.",
      categories: ["MULTIPLAYER"],
      tags: ["multiplayer", "ruleset", "hardcore"],
      games: manifest.games,
      license: "MIT",
      repo: REPO,
      github: `https://github.com/${REPO}`,
      api: manifest.api,
      game_version: manifest.game_version,
      profile: manifest.profile,
      // it changes what a link battle means, which is worth flagging
      affects_link: true,
      permissions: manifest.permissions,
      dependencies: manifest.dependencies,
      conflicts: manifest.conflicts,
      description_url: `https://github.com/${REPO}#readme`,
      first_release: "2026-08-23",
      last_release: (release.publishedAt || "").slice(0, 10),
      latest: {
        version,
        tag: release.tagName,
        name: release.name,
        prerelease: release.isPrerelease === true,
        published_at: release.publishedAt,
        zip: { name: zip.name, url: zip.url, size: zip.size },
      },
      // "ok" tells the launcher the release data below is real, so it shows
      // that version rather than falling back to the declared one
      update_check: "ok",
    },
  ],
};

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify(doc, null, 2) + "\n");
console.log(`${OUT}: ${manifest.id} ${version} -> ${zip.name}`);
