import "./style.css";
import { app, errorText } from "../../_shared/kit";
import { h } from "../../_shared/dom";
import { rootLabel } from "../../_shared/format";
import { loadingView } from "../../_shared/busy";
import { Tree } from "./tree";
import { Viewer } from "./viewer";

async function main(): Promise<void> {
  const root = document.getElementById("root")!;
  root.append(loadingView("Loading…"));

  let args;
  try {
    args = await app.openArgs();
  } catch (e) {
    root.replaceChildren(h("div", { class: "notice error" }, h("h2", null, "Can't open"), h("div", null, errorText(e))));
    return;
  }
  let top;
  try {
    top = await app.fs.stat(".");
  } catch (e) {
    root.replaceChildren(h("div", { class: "notice error" }, h("h2", null, "Can't read this location"), h("div", null, errorText(e))));
    return;
  }
  // A folder picked in the app's dialog arrives without a path: call it by the name of the granted root.
  const label = rootLabel(args.path, top.name, ".");

  const viewer = new Viewer();
  const bar = h("div", { class: "bar" }, h("span", { class: "path", title: label }, label));

  // The user granted a single file: no tree, just the file.
  if (top.kind === "file") {
    root.replaceChildren(bar, viewer.el);
    document.title = `File view: ${label}`;
    void viewer.open(".", top, label.split("/").pop() || label);
    return;
  }

  const tree = new Tree();
  const split = h("div", { class: "split" }, tree.el, viewer.el);
  root.replaceChildren(bar, split);
  document.title = `File view: ${label}`;

  tree.onOpen = (path, entry) => void viewer.open(path, entry);
  viewer.onNavigate = (path) => {
    app.fs.stat(path).then(
      (entry) => {
        if (entry.kind === "file") {
          void tree.reveal(path);
          void viewer.open(path, entry);
        }
      },
      (e) => viewer.empty(`Can't open ${path}: ${errorText(e)}`),
    );
  };

  try {
    await tree.loadRoot();
  } catch {
    return; // the reason is shown in the tree
  }

  // A seat or the user can ask for a file inside the folder: #path in the URL is
  // not used (the pane URL is the app's), so open the README if there is one.
  const readme = await app.fs.list(".").then(
    (l) => l.entries.find((x) => x.kind === "file" && /^readme(\.md|\.markdown|\.txt)?$/i.test(x.name)),
    () => undefined,
  );
  if (readme) {
    void tree.reveal(readme.name);
    void viewer.open(readme.name, readme);
  }
}

void main();
