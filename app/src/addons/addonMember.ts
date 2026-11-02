// The type core gives a member an add-on joined as. Such a member is a name other members can write to,
// not an agent with a CLI to start.
export const ADDON_MEMBER_TYPE = "app-addon";

export function isAddonMember(m: { types: string[] }): boolean {
  return m.types.length > 0 && m.types.every((t) => t === ADDON_MEMBER_TYPE);
}
