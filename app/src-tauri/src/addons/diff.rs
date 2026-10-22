//! The `git.diff` result of the app add-on protocol, computed in Rust.
//!
//! The caller reads the two sides (blobs, or a blob and a worktree file) and hands
//! the bytes in; this module only diffs them and shapes the answer exactly as
//! `DiffResult` in `app/addon-kit/protocol.d.ts`. It never touches the disk, and
//! it never runs git. Word-level highlights are the view's job, not done here.

use serde::Serialize;
use similar::{capture_diff_slices, group_diff_ops, Algorithm, DiffOp};

/// How much unchanged text to keep around each change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Context {
    Lines(usize),
    /// Every line of the file, as one hunk.
    All,
}

impl Default for Context {
    fn default() -> Self {
        Context::Lines(3)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub context: Context,
    /// A file with either side larger than this is not diffed (`tooLarge`).
    pub max_file_bytes: usize,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            context: Context::default(),
            max_file_bytes: 2 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Relation {
    Renamed,
    Copied,
}

/// One file to compare. `old: None` means the file does not exist on the base
/// side (added); `new: None` means it does not exist on the head side (deleted).
#[derive(Debug, Clone, Default)]
pub struct FileInput<'a> {
    /// Path on the head side (the base side for a deleted file).
    pub path: String,
    /// Set by the caller only when it knows the file was renamed or copied.
    pub old_path: Option<String>,
    pub relation: Option<Relation>,
    /// 0..=100, when the caller measured it.
    pub similarity: Option<u8>,
    pub old: Option<&'a [u8]>,
    pub new: Option<&'a [u8]>,
    /// Git modes such as "100644", "100755", "120000".
    pub old_mode: Option<String>,
    pub new_mode: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DiffStatus {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    Typechange,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LineType {
    Context,
    Add,
    Del,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffLine {
    #[serde(rename = "type")]
    pub kind: LineType,
    /// Without the line terminator (`\n`, and a `\r` before it).
    pub text: String,
    pub old_no: Option<u32>,
    pub new_no: Option<u32>,
    /// This side's file has no newline at the end of this line.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub no_eol: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffHunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub lines: Vec<DiffLine>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffFile {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    pub status: DiffStatus,
    pub binary: bool,
    pub additions: u32,
    pub deletions: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub similarity: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_mode: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub too_large: bool,
    pub hunks: Vec<DiffHunk>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BaseRev {
    pub rev: String,
    pub sha: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HeadRev {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rev: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha: Option<String>,
    pub worktree: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiffResult {
    pub base: BaseRev,
    pub head: HeadRev,
    pub files: Vec<DiffFile>,
    pub additions: u32,
    pub deletions: u32,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
}

impl DiffResult {
    /// Totals are summed here so they always agree with `files`.
    pub fn new(base: BaseRev, head: HeadRev, files: Vec<DiffFile>, truncated: bool) -> Self {
        let additions = files.iter().map(|f| f.additions).sum();
        let deletions = files.iter().map(|f| f.deletions).sum();
        DiffResult {
            base,
            head,
            files,
            additions,
            deletions,
            truncated,
        }
    }
}

/// Git treats a file as binary when a NUL byte appears in its first 8000 bytes.
const BINARY_PROBE: usize = 8000;

pub fn is_binary(bytes: &[u8]) -> bool {
    bytes.iter().take(BINARY_PROBE).any(|&b| b == 0)
}

/// Lines with their terminator kept, so "a" and "a\n" compare as different.
fn lines_of(bytes: &[u8]) -> Vec<&[u8]> {
    bytes.split_inclusive(|&b| b == b'\n').collect()
}

fn text_of(line: &[u8]) -> String {
    let body = line.strip_suffix(b"\n").unwrap_or(line);
    let body = if line.ends_with(b"\n") {
        body.strip_suffix(b"\r").unwrap_or(body)
    } else {
        body
    };
    String::from_utf8_lossy(body).into_owned()
}

fn no_eol(line: &[u8]) -> bool {
    !line.ends_with(b"\n")
}

fn file_type_of(mode: &str) -> &str {
    mode.get(..3).unwrap_or(mode)
}

fn status_of(input: &FileInput<'_>) -> DiffStatus {
    if input.old.is_none() {
        return DiffStatus::Added;
    }
    if input.new.is_none() {
        return DiffStatus::Deleted;
    }
    if input.old_path.is_some() {
        match input.relation {
            Some(Relation::Copied) => return DiffStatus::Copied,
            Some(Relation::Renamed) | None => return DiffStatus::Renamed,
        }
    }
    if let (Some(a), Some(b)) = (&input.old_mode, &input.new_mode) {
        if file_type_of(a) != file_type_of(b) {
            return DiffStatus::Typechange;
        }
    }
    DiffStatus::Modified
}

fn count_lines(bytes: &[u8]) -> u32 {
    lines_of(bytes).len() as u32
}

/// Compare one file. Always returns a `DiffFile`; see `diff_files` to drop
/// files that did not change.
pub fn diff_file(input: &FileInput<'_>, opts: &Options) -> DiffFile {
    let status = status_of(input);
    let old = input.old.unwrap_or(&[]);
    let new = input.new.unwrap_or(&[]);
    let mut out = DiffFile {
        path: input.path.clone(),
        old_path: input.old_path.clone(),
        status,
        binary: false,
        additions: 0,
        deletions: 0,
        similarity: input.similarity,
        old_mode: input.old_mode.clone(),
        new_mode: input.new_mode.clone(),
        too_large: false,
        hunks: Vec::new(),
    };

    if is_binary(old) || is_binary(new) {
        out.binary = true;
        return out;
    }
    if old.len() > opts.max_file_bytes || new.len() > opts.max_file_bytes {
        // Not diffed. A file that exists on one side only still has an exact count.
        out.too_large = true;
        if input.old.is_none() {
            out.additions = count_lines(new);
        } else if input.new.is_none() {
            out.deletions = count_lines(old);
        }
        return out;
    }

    let a = lines_of(old);
    let b = lines_of(new);
    let ops = capture_diff_slices(Algorithm::Myers, &a, &b);
    let n = match opts.context {
        Context::Lines(n) => n,
        Context::All => usize::MAX / 4,
    };
    for group in group_diff_ops(ops, n) {
        let mut lines = Vec::new();
        for op in &group {
            match *op {
                DiffOp::Equal {
                    old_index,
                    new_index,
                    len,
                } => {
                    for k in 0..len {
                        let (i, j) = (old_index + k, new_index + k);
                        // The terminator can only be missing on a last line, and then
                        // both sides ended there, so either side's flag is the line's.
                        lines.push(DiffLine {
                            kind: LineType::Context,
                            text: text_of(a[i]),
                            old_no: Some(i as u32 + 1),
                            new_no: Some(j as u32 + 1),
                            no_eol: no_eol(a[i]),
                        });
                    }
                }
                DiffOp::Delete {
                    old_index, old_len, ..
                } => push_del(&mut lines, &a, old_index, old_len),
                DiffOp::Insert {
                    new_index, new_len, ..
                } => push_add(&mut lines, &b, new_index, new_len),
                DiffOp::Replace {
                    old_index,
                    old_len,
                    new_index,
                    new_len,
                } => {
                    push_del(&mut lines, &a, old_index, old_len);
                    push_add(&mut lines, &b, new_index, new_len);
                }
            }
        }
        let old_lines = lines.iter().filter(|l| l.kind != LineType::Add).count() as u32;
        let new_lines = lines.iter().filter(|l| l.kind != LineType::Del).count() as u32;
        let first_old = group.first().map(|o| o.old_range().start).unwrap_or(0) as u32;
        let first_new = group.first().map(|o| o.new_range().start).unwrap_or(0) as u32;
        // Unified-diff convention: an empty range starts at the line before it.
        let old_start = if old_lines == 0 {
            first_old
        } else {
            first_old + 1
        };
        let new_start = if new_lines == 0 {
            first_new
        } else {
            first_new + 1
        };
        out.additions += lines.iter().filter(|l| l.kind == LineType::Add).count() as u32;
        out.deletions += lines.iter().filter(|l| l.kind == LineType::Del).count() as u32;
        out.hunks.push(DiffHunk {
            old_start,
            old_lines,
            new_start,
            new_lines,
            lines,
        });
    }
    out
}

fn push_del(lines: &mut Vec<DiffLine>, a: &[&[u8]], at: usize, len: usize) {
    for k in 0..len {
        lines.push(DiffLine {
            kind: LineType::Del,
            text: text_of(a[at + k]),
            old_no: Some((at + k) as u32 + 1),
            new_no: None,
            no_eol: no_eol(a[at + k]),
        });
    }
}

fn push_add(lines: &mut Vec<DiffLine>, b: &[&[u8]], at: usize, len: usize) {
    for k in 0..len {
        lines.push(DiffLine {
            kind: LineType::Add,
            text: text_of(b[at + k]),
            old_no: None,
            new_no: Some((at + k) as u32 + 1),
            no_eol: no_eol(b[at + k]),
        });
    }
}

/// Compare many files and keep the ones that changed: different content, a
/// different mode, or a rename the caller reported.
pub fn diff_files(inputs: &[FileInput<'_>], opts: &Options) -> Vec<DiffFile> {
    inputs
        .iter()
        .filter(|i| {
            i.old.is_none()
                || i.new.is_none()
                || i.old_path.is_some()
                || i.old != i.new
                || i.old_mode != i.new_mode
        })
        .map(|i| diff_file(i, opts))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input<'a>(path: &str, old: Option<&'a [u8]>, new: Option<&'a [u8]>) -> FileInput<'a> {
        FileInput {
            path: path.into(),
            old,
            new,
            ..Default::default()
        }
    }

    fn kinds(h: &DiffHunk) -> Vec<(LineType, &str)> {
        h.lines.iter().map(|l| (l.kind, l.text.as_str())).collect()
    }

    use LineType::{Add, Context as Ctx, Del};

    #[test]
    fn added_file() {
        let f = diff_file(&input("a.txt", None, Some(b"x\ny\n")), &Options::default());
        assert_eq!(f.status, DiffStatus::Added);
        assert_eq!((f.additions, f.deletions), (2, 0));
        assert_eq!(f.hunks.len(), 1);
        let h = &f.hunks[0];
        assert_eq!(
            (h.old_start, h.old_lines, h.new_start, h.new_lines),
            (0, 0, 1, 2)
        );
        assert_eq!(kinds(h), vec![(Add, "x"), (Add, "y")]);
        assert_eq!(h.lines[0].old_no, None);
        assert_eq!(h.lines[1].new_no, Some(2));
    }

    #[test]
    fn deleted_file() {
        let f = diff_file(&input("a.txt", Some(b"x\ny\n"), None), &Options::default());
        assert_eq!(f.status, DiffStatus::Deleted);
        assert_eq!((f.additions, f.deletions), (0, 2));
        let h = &f.hunks[0];
        assert_eq!(
            (h.old_start, h.old_lines, h.new_start, h.new_lines),
            (1, 2, 0, 0)
        );
        assert_eq!(kinds(h), vec![(Del, "x"), (Del, "y")]);
    }

    #[test]
    fn modified_file_with_context() {
        let old = b"1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";
        let new = b"1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n10\n";
        let f = diff_file(&input("n.txt", Some(old), Some(new)), &Options::default());
        assert_eq!(f.status, DiffStatus::Modified);
        assert_eq!((f.additions, f.deletions), (1, 1));
        let h = &f.hunks[0];
        assert_eq!(
            (h.old_start, h.old_lines, h.new_start, h.new_lines),
            (2, 7, 2, 7)
        );
        assert_eq!(
            kinds(h),
            vec![
                (Ctx, "2"),
                (Ctx, "3"),
                (Ctx, "4"),
                (Del, "5"),
                (Add, "FIVE"),
                (Ctx, "6"),
                (Ctx, "7"),
                (Ctx, "8")
            ]
        );
        let del = &h.lines[3];
        assert_eq!((del.old_no, del.new_no), (Some(5), None));
        let add = &h.lines[4];
        assert_eq!((add.old_no, add.new_no), (None, Some(5)));
    }

    #[test]
    fn context_zero_gives_bare_changes_and_two_hunks() {
        let old = b"a\nb\nc\nd\ne\n";
        let new = b"A\nb\nc\nd\nE\n";
        let opts = Options {
            context: Context::Lines(0),
            ..Options::default()
        };
        let f = diff_file(&input("x", Some(old), Some(new)), &opts);
        assert_eq!(f.hunks.len(), 2);
        assert_eq!(kinds(&f.hunks[0]), vec![(Del, "a"), (Add, "A")]);
        assert_eq!(kinds(&f.hunks[1]), vec![(Del, "e"), (Add, "E")]);
        assert_eq!((f.hunks[1].old_start, f.hunks[1].new_start), (5, 5));
    }

    #[test]
    fn context_all_is_one_hunk_with_every_line() {
        let old = b"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n";
        let new = b"A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n";
        let opts = Options {
            context: Context::All,
            ..Options::default()
        };
        let f = diff_file(&input("x", Some(old), Some(new)), &opts);
        assert_eq!(f.hunks.len(), 1);
        let h = &f.hunks[0];
        assert_eq!(
            (h.old_start, h.old_lines, h.new_start, h.new_lines),
            (1, 12, 1, 12)
        );
        assert_eq!(h.lines.len(), 14);
        assert_eq!(h.lines.iter().filter(|l| l.kind == Ctx).count(), 10);
    }

    #[test]
    fn default_context_leaves_distant_changes_in_separate_hunks() {
        let mut old = String::new();
        let mut new = String::new();
        for i in 1..=30 {
            old.push_str(&format!("l{i}\n"));
            new.push_str(&if i == 2 || i == 29 {
                format!("L{i}\n")
            } else {
                format!("l{i}\n")
            });
        }
        let f = diff_file(
            &input("x", Some(old.as_bytes()), Some(new.as_bytes())),
            &Options::default(),
        );
        assert_eq!(f.hunks.len(), 2);
        assert_eq!(f.hunks[0].old_start, 1);
        assert_eq!(f.hunks[1].old_start, 26);
    }

    #[test]
    fn missing_newline_at_end_is_flagged_on_the_right_side() {
        let f = diff_file(
            &input("x", Some(b"a\nb"), Some(b"a\nb\n")),
            &Options::default(),
        );
        let h = &f.hunks[0];
        assert_eq!(kinds(h), vec![(Ctx, "a"), (Del, "b"), (Add, "b")]);
        assert!(!h.lines[0].no_eol);
        assert!(h.lines[1].no_eol, "base side lacks the newline");
        assert!(!h.lines[2].no_eol);
    }

    #[test]
    fn unchanged_last_line_without_newline_is_a_context_line_with_the_flag() {
        let f = diff_file(
            &input("x", Some(b"a\nb"), Some(b"A\nb")),
            &Options::default(),
        );
        let last = f.hunks[0].lines.last().unwrap();
        assert_eq!(
            (last.kind, last.text.as_str(), last.no_eol),
            (Ctx, "b", true)
        );
    }

    #[test]
    fn crlf_text_drops_the_cr_but_an_ending_change_is_a_change() {
        let same = diff_file(
            &input("x", Some(b"a\r\nb\r\n"), Some(b"a\r\nB\r\n")),
            &Options::default(),
        );
        assert_eq!(
            kinds(&same.hunks[0]),
            vec![(Ctx, "a"), (Del, "b"), (Add, "B")]
        );
        // Only the line ending changed: the two lines look alike but are reported.
        let eol = diff_file(
            &input("x", Some(b"a\r\n"), Some(b"a\n")),
            &Options::default(),
        );
        assert_eq!((eol.additions, eol.deletions), (1, 1));
        assert_eq!(eol.hunks[0].lines[0].text, "a");
        assert_eq!(eol.hunks[0].lines[1].text, "a");
    }

    #[test]
    fn binary_either_side_carries_no_hunks() {
        let f = diff_file(
            &input("i.png", Some(b"\x89PNG\0\0"), Some(b"\x89PNG\0\x01")),
            &Options::default(),
        );
        assert!(f.binary);
        assert!(f.hunks.is_empty());
        assert_eq!((f.additions, f.deletions), (0, 0));
        let g = diff_file(&input("i", None, Some(b"ok\0")), &Options::default());
        assert!(g.binary);
    }

    #[test]
    fn a_nul_after_the_probe_window_is_text() {
        let mut v = vec![b'a'; 8000];
        v.extend_from_slice(b"\0\n");
        assert!(!is_binary(&v));
    }

    #[test]
    fn empty_files() {
        let added = diff_file(&input("e", None, Some(b"")), &Options::default());
        assert_eq!(added.status, DiffStatus::Added);
        assert!(added.hunks.is_empty());
        let filled = diff_file(&input("e", Some(b""), Some(b"x\n")), &Options::default());
        assert_eq!(filled.status, DiffStatus::Modified);
        assert_eq!(kinds(&filled.hunks[0]), vec![(Add, "x")]);
        assert_eq!(filled.hunks[0].old_start, 0);
        let emptied = diff_file(&input("e", Some(b"x\n"), Some(b"")), &Options::default());
        assert_eq!(kinds(&emptied.hunks[0]), vec![(Del, "x")]);
        assert_eq!(emptied.hunks[0].new_start, 0);
        let both = diff_file(&input("e", Some(b""), Some(b"")), &Options::default());
        assert!(both.hunks.is_empty());
    }

    #[test]
    fn size_cap_sets_too_large_and_skips_the_diff() {
        let opts = Options {
            max_file_bytes: 10,
            ..Options::default()
        };
        let big = b"line one\nline two\nline three\n";
        let f = diff_file(&input("b", Some(b"x\n"), Some(big)), &opts);
        assert!(f.too_large);
        assert!(f.hunks.is_empty());
        let added = diff_file(&input("b", None, Some(big)), &opts);
        assert!(added.too_large);
        assert_eq!(
            added.additions, 3,
            "an added file still gets an exact count"
        );
        let gone = diff_file(&input("b", Some(big), None), &opts);
        assert_eq!(gone.deletions, 3);
    }

    #[test]
    fn rename_only_when_the_caller_says_so() {
        let plain = diff_file(
            &input("n.txt", Some(b"a\n"), Some(b"b\n")),
            &Options::default(),
        );
        assert_eq!(plain.status, DiffStatus::Modified);
        assert_eq!(plain.old_path, None);
        let mut moved = input("new.txt", Some(b"a\n"), Some(b"a\n"));
        moved.old_path = Some("old.txt".into());
        moved.similarity = Some(100);
        let f = diff_file(&moved, &Options::default());
        assert_eq!(f.status, DiffStatus::Renamed);
        assert_eq!(f.old_path.as_deref(), Some("old.txt"));
        assert_eq!(f.similarity, Some(100));
        assert!(f.hunks.is_empty());
        moved.relation = Some(Relation::Copied);
        assert_eq!(
            diff_file(&moved, &Options::default()).status,
            DiffStatus::Copied
        );
    }

    #[test]
    fn mode_change_and_type_change() {
        let mut i = input("run.sh", Some(b"x\n"), Some(b"x\n"));
        i.old_mode = Some("100644".into());
        i.new_mode = Some("100755".into());
        let f = diff_file(&i, &Options::default());
        assert_eq!(f.status, DiffStatus::Modified);
        assert!(f.hunks.is_empty());
        assert_eq!(
            (f.old_mode.as_deref(), f.new_mode.as_deref()),
            (Some("100644"), Some("100755"))
        );
        i.new_mode = Some("120000".into());
        assert_eq!(
            diff_file(&i, &Options::default()).status,
            DiffStatus::Typechange
        );
    }

    #[test]
    fn diff_files_drops_unchanged_files_only() {
        let inputs = vec![
            input("same", Some(b"x\n"), Some(b"x\n")),
            input("changed", Some(b"x\n"), Some(b"y\n")),
            input("new", None, Some(b"")),
        ];
        let files = diff_files(&inputs, &Options::default());
        let names: Vec<_> = files.iter().map(|f| f.path.as_str()).collect();
        assert_eq!(names, vec!["changed", "new"]);
    }

    #[test]
    fn invalid_utf8_text_is_replaced_not_dropped() {
        let f = diff_file(&input("l1", None, Some(b"caf\xe9\n")), &Options::default());
        assert_eq!(f.hunks[0].lines[0].text, "caf\u{fffd}");
    }

    #[test]
    fn result_totals_follow_the_files_and_serialize_to_the_protocol_shape() {
        let files = diff_files(
            &[
                input("a", Some(b"x\n"), Some(b"y\n")),
                input("b", None, Some(b"1\n2\n")),
            ],
            &Options::default(),
        );
        let r = DiffResult::new(
            BaseRev {
                rev: "HEAD".into(),
                sha: "abc".into(),
            },
            HeadRev {
                rev: None,
                sha: None,
                worktree: true,
            },
            files,
            false,
        );
        assert_eq!((r.additions, r.deletions), (3, 1));
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["head"], serde_json::json!({ "worktree": true }));
        assert!(v.get("truncated").is_none());
        let f0 = &v["files"][0];
        assert_eq!(f0["status"], "modified");
        assert!(f0.get("tooLarge").is_none() && f0.get("oldPath").is_none());
        let line = &f0["hunks"][0]["lines"][0];
        assert_eq!(line["type"], "del");
        assert_eq!(line["oldNo"], 1);
        assert_eq!(line["newNo"], serde_json::Value::Null);
        assert!(line.get("noEol").is_none());
        assert_eq!(f0["hunks"][0]["oldStart"], 1);
    }
}
