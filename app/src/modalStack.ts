// Modals stack: a dialog opened over Settings is above it, and only the top one answers Escape or a click
// on its backdrop. Every modal registers while it is mounted, whether or not it can be closed (a busy dialog
// has no way out and must still keep the ones under it from closing).

export type ModalStack = {
  push(id: number): void;
  remove(id: number): void;
  isTop(id: number): boolean;
};

export function createModalStack(): ModalStack {
  const ids: number[] = [];
  return {
    push: (id) => void ids.push(id),
    remove: (id) => {
      const i = ids.lastIndexOf(id);
      if (i >= 0) ids.splice(i, 1);
    },
    isTop: (id) => ids.length > 0 && ids[ids.length - 1] === id,
  };
}

/** What a modal does with Escape: close itself, but only when it is the top one and can be closed. */
export function escapeCloses(stack: ModalStack, id: number, onClose: (() => void) | undefined): boolean {
  if (!onClose || !stack.isTop(id)) return false;
  onClose();
  return true;
}

export const modalStack = createModalStack();
let nextId = 0;
export const newModalId = (): number => ++nextId;
