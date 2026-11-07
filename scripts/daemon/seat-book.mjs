// What agmsgd last observed about each seat, kept in memory only.
//
// A seat is polled every cycle and almost always gives the same answer, so
// writing each answer to install.db cost one write transaction per seat per
// cycle. The answers are of use to `agmsg daemon status` and the doctor
// report, which ask the running agmsgd for them over its control socket, so
// nothing needs to outlive the process: a fresh daemon fills the book on its
// first poll.
//
// `since` is when the seat last changed state or reason, not when it was last
// looked at.

export function createSeatBook(now = Date.now) {
  const seats = new Map();
  let polls = 0;

  return {
    // `thread`/`socket`/`codexHome` that are null keep the value already held,
    // as the old UPSERT's COALESCE did.
    set(seat, { state, reason = '', thread = null, codexHome = null, messagingSocket = null }) {
      const before = seats.get(seat);
      const changed = !before || before.state !== state || before.reason !== reason;
      seats.set(seat, {
        seat,
        state,
        reason,
        thread: thread ?? before?.thread ?? null,
        codex_home: codexHome ?? before?.codex_home ?? null,
        messaging_socket: messagingSocket ?? before?.messaging_socket ?? null,
        since: changed ? new Date(now()).toISOString() : before.since,
      });
    },
    get: (seat) => seats.get(seat),
    keys: () => [...seats.keys()],
    delete: (seat) => seats.delete(seat),
    pollFinished() { polls += 1; },
    // Sorted by seat key, like the table's ORDER BY.
    snapshot() {
      return { polled: polls > 0, seats: [...seats.values()].sort((a, b) => (a.seat < b.seat ? -1 : a.seat > b.seat ? 1 : 0)) };
    },
  };
}
