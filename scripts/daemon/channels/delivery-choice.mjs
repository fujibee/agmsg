// The project's explicit delivery choice (see agmsg_delivery_choice_get in
// scripts/lib/daemon-state.sh): lines "<type>\t<project>\t<value>" in
// run/delivery-choice, written only by `agmsg delivery <value>`. A value other
// than "agmsgd" is the project's decision not to use agmsgd. No line, or an
// unreadable file, means no choice was made and agmsgd delivers as before.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function readDeliveryChoice(installRoot, type, project) {
  let text;
  try {
    text = readFileSync(join(installRoot, "run", "delivery-choice"), "utf8");
  } catch {
    return "";
  }
  let choice = "";
  for (const line of text.split(/\r?\n/)) {
    const [lineType, lineProject, value] = line.split("\t");
    if (lineType === type && lineProject === project && /^[a-z]+$/.test(value ?? "")) choice = value;
  }
  return choice;
}

export function optedOutOfAgmsgd(installRoot, type, project) {
  const choice = readDeliveryChoice(installRoot, type, project);
  return choice && choice !== "agmsgd" ? choice : "";
}
