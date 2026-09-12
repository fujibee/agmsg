"use strict";

const fs = require("node:fs");
const path = require("node:path");

function normalizeProjectPath(value) {
  if (typeof value !== "string" || value.length === 0) return "";
  let normalized = value.replace(/\\/g, "/").replace(/\/+/g, "/");
  const drive = /^([A-Za-z]):(?:\/|$)/.exec(normalized);
  if (drive) {
    normalized = `/${drive[1].toLowerCase()}${normalized.slice(2)}`;
  } else if (/^\/[A-Za-z](?:\/|$)/.test(normalized)) {
    normalized = `/${normalized[1].toLowerCase()}${normalized.slice(2)}`;
  }
  if (normalized.length > 1) normalized = normalized.replace(/\/+$/, "");
  return normalized;
}

function registrationList(agent) {
  if (Array.isArray(agent && agent.registrations)) return agent.registrations;
  if (agent && (agent.type || agent.project)) {
    return [{ type: agent.type, project: agent.project }];
  }
  return [];
}

function readTeamConfigs(skillDir) {
  const teamsDir = path.join(skillDir, "teams");
  if (!fs.existsSync(teamsDir)) return [];
  return fs
    .readdirSync(teamsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(teamsDir, entry.name, "config.json"))
    .filter((file) => fs.existsSync(file))
    .map((file) => {
      try {
        const config = JSON.parse(fs.readFileSync(file, "utf8"));
        return config && typeof config === "object" ? config : null;
      } catch (_) {
        return null;
      }
    })
    .filter(Boolean);
}

function dedupeIdentities(identities) {
  const seen = new Set();
  return identities.filter((identity) => {
    const key = `${identity.team}\t${identity.name}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function resolveIdentities({ skillDir, project, type, team, name }) {
  if (!skillDir || !project || !type) {
    throw new Error("skillDir, project, and type are required");
  }

  const wantedProject = normalizeProjectPath(project);
  const configs = readTeamConfigs(skillDir);
  const availableTeams = [];
  const exact = [];
  const suggestions = [];

  for (const config of configs) {
    const teamName = typeof config.name === "string" ? config.name : "";
    if (!teamName) continue;
    availableTeams.push(teamName);
    for (const [agentName, agent] of Object.entries(config.agents || {})) {
      for (const registration of registrationList(agent)) {
        if (!registration || registration.type !== type) continue;
        const identity = {
          team: teamName,
          name: agentName,
          project: registration.project || "",
          type: registration.type,
        };
        suggestions.push(identity);
        if (normalizeProjectPath(registration.project) === wantedProject) {
          exact.push(identity);
        }
      }
    }
  }

  const filterExplicit = (identity) =>
    (!team || identity.team === team) && (!name || identity.name === name);
  const identities = dedupeIdentities(exact.filter(filterExplicit));
  const suggested = dedupeIdentities(suggestions.filter(filterExplicit));

  if (identities.length > 0) {
    const names = new Set(identities.map((identity) => identity.name));
    return {
      status: names.size === 1 ? "single" : "multiple",
      identities,
      availableTeams,
    };
  }
  if (suggested.length > 0) {
    return { status: "suggest", identities: suggested, availableTeams };
  }
  return { status: "not_joined", identities: [], availableTeams };
}

module.exports = {
  normalizeProjectPath,
  resolveIdentities,
};
