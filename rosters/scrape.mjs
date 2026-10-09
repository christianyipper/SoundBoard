// Scrapes JPHL rosters and season player stats into rosters.json.
//
// Rosters are plain server-rendered HTML, so they're fetched directly.
// Team statistics pages are rendered by Blazor Server over a websocket, so
// those are loaded in headless Chromium.

import { chromium } from 'playwright';
import { readFile, writeFile } from 'node:fs/promises';

const BASE = 'https://www.juniorprospectshockeyleague.com';
const OUTPUT = new URL('./rosters.json', import.meta.url);
const USER_AGENT = 'Mozilla/5.0 (Scorely roster sync)';

const decodeEntities = (s) =>
  s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ');

const stripTags = (s) => decodeEntities(s.replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim();

async function fetchHTML(path) {
  const res = await fetch(BASE + path, { headers: { 'User-Agent': USER_AGENT } });
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return res.text();
}

/** Division ids/names from the rosters page's division dropdown. */
function parseDivisions(html) {
  const divisions = new Map();
  for (const [, id, name] of html.matchAll(/href="\/division\/0\/(\d+)\/rosters"[^>]*>([^<]+)<\/a>/g)) {
    if (id !== '0') divisions.set(Number(id), stripTags(name));
  }
  return [...divisions].map(([id, name]) => ({ id, name }));
}

/** Every roster row of a division: team, jersey, player name, position. */
function parseRoster(html, divisionName) {
  const teams = new Map();
  let seasonId = null;
  const tbody = html.slice(html.indexOf('<tbody'), html.indexOf('</tbody>'));
  for (const [, row] of tbody.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/g)) {
    const cells = [...row.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((m) => m[1]);
    if (cells.length < 4) continue;
    const teamLink = cells[0].match(/\/team\/(\d+)\/0\/\d+\/(\d+)/);
    const playerLink = cells[2].match(/\/player\/(\d+)/);
    if (!teamLink || !playerLink) continue;
    seasonId = Number(teamLink[1]);
    const teamId = Number(teamLink[2]);
    const teamName = stripTags(cells[0]).replace(new RegExp(`^${divisionName}\\s*-\\s*`), '');
    if (!teams.has(teamId)) teams.set(teamId, { id: teamId, name: teamName, gp: 0, players: [] });
    teams.get(teamId).players.push({
      id: Number(playerLink[1]),
      number: stripTags(cells[1]),
      name: stripTags(cells[2]),
      position: stripTags(cells[3]),
      gp: 0,
      goals: 0,
      assists: 0,
      points: 0,
      pim: 0,
    });
  }
  return { seasonId, teams: [...teams.values()] };
}

/**
 * A team's statistics page: its games played (from the standings table) and
 * the skater stats table, keyed by player id.
 */
async function fetchTeamStats(page, seasonId, divisionId, teamId) {
  const url = `${BASE}/team/${seasonId}/0/${divisionId}/${teamId}/statistics`;
  await page.goto(url, { waitUntil: 'networkidle', timeout: 60_000 });
  await page.waitForSelector('table thead th:text-is("G")', { timeout: 30_000 });
  return page.$$eval('table', (tables, teamId) => {
    const stats = {};
    let teamGP = null;
    for (const table of tables) {
      const headers = [...table.querySelectorAll('thead th')].map((th) => th.innerText.trim());
      const col = (name) => headers.indexOf(name);
      if (col('GP') >= 0 && col('Name') < 0) {
        const teamRow = [...table.querySelectorAll('tbody tr')].find((row) =>
          row.querySelector(`a[href$="/${teamId}/statistics"]`)
        );
        const gp = teamRow?.querySelectorAll('td')[col('GP')]?.innerText.trim();
        if (gp) teamGP = Number(gp) || 0;
      }
      if (col('G') < 0 || col('Name') < 0) continue;
      for (const row of table.querySelectorAll('tbody tr')) {
        const cells = [...row.querySelectorAll('td')];
        const link = cells[col('Name')]?.querySelector('a')?.getAttribute('href') ?? '';
        const id = link.match(/\/player\/(\d+)/)?.[1];
        if (!id) continue;
        const num = (name) => (col(name) < 0 ? 0 : Number(cells[col(name)]?.innerText.trim()) || 0);
        stats[id] = { gp: num('GP'), goals: num('G'), assists: num('A'), points: num('PTS'), pim: num('PIM') };
      }
    }
    return { teamGP, players: stats };
  }, teamId);
}

async function loadPrevious() {
  try {
    return JSON.parse(await readFile(OUTPUT, 'utf8'));
  } catch {
    return null;
  }
}

async function main() {
  const previous = await loadPrevious();
  const previousPlayers = new Map();
  const previousTeamGP = new Map();
  for (const division of previous?.divisions ?? []) {
    for (const team of division.teams) {
      previousTeamGP.set(team.id, team.gp);
      for (const player of team.players) previousPlayers.set(`${team.id}:${player.id}`, player);
    }
  }

  const divisions = parseDivisions(await fetchHTML('/division/0/0/rosters'));
  if (divisions.length === 0) throw new Error('No divisions found');

  const browser = await chromium.launch();
  const page = await browser.newPage({ userAgent: USER_AGENT });
  let seasonId = null;
  let failedTeams = 0;

  const output = [];
  for (const division of divisions) {
    const roster = parseRoster(await fetchHTML(`/division/0/${division.id}/rosters`), division.name);
    seasonId ??= roster.seasonId;
    console.log(`${division.name}: ${roster.teams.length} teams`);

    for (const team of roster.teams) {
      let stats = null;
      for (let attempt = 1; attempt <= 2 && !stats; attempt++) {
        try {
          stats = await fetchTeamStats(page, roster.seasonId, division.id, team.id);
        } catch (error) {
          console.warn(`  ${team.name}: stats attempt ${attempt} failed (${error.message})`);
        }
      }
      if (!stats) failedTeams++;
      for (const player of team.players) {
        // Keep the last known stats rather than zeroing them if this team's page failed.
        const source = stats ? stats.players[player.id] : previousPlayers.get(`${team.id}:${player.id}`);
        if (source) {
          const { gp, goals, assists, points, pim } = source;
          Object.assign(player, { gp, goals, assists, points, pim });
        }
      }
      // Fall back to the most games any player has if the standings row is missing.
      team.gp = (stats ? stats.teamGP : previousTeamGP.get(team.id)) ?? Math.max(0, ...team.players.map((p) => p.gp));
      team.players.sort((a, b) => Number(a.number) - Number(b.number));
      console.log(`  ${team.name}: ${team.players.length} players${stats ? '' : ' (stats kept from previous run)'}`);
    }
    output.push({ id: division.id, name: division.name, teams: roster.teams });
  }
  await browser.close();

  await writeFile(
    OUTPUT,
    JSON.stringify({ updatedAt: new Date().toISOString(), seasonId, divisions: output }, null, 2) + '\n'
  );
  console.log(`Wrote rosters.json (${failedTeams} team(s) without fresh stats)`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
