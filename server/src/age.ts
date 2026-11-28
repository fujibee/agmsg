import { Encrypter, identityToRecipient } from "age-encryption";

export const AGE_RECIPIENT = /^age1[0-9a-z]{58}$/u;
export const AGE_IDENTITY = /^AGE-SECRET-KEY-1[0-9A-Z]{58}$/u;

// The recipient an age identity belongs to, or null when the string is not a
// well-formed identity.
export async function recipientOfIdentity(identity: string): Promise<string | null> {
  if (!AGE_IDENTITY.test(identity)) return null;
  try {
    return await identityToRecipient(identity);
  } catch {
    return null;
  }
}

// An age file (binary) holding `plaintext`, readable only by `recipient`.
export async function sealToRecipient(plaintext: string, recipient: string): Promise<Uint8Array> {
  const encrypter = new Encrypter();
  encrypter.addRecipient(recipient);
  return encrypter.encrypt(plaintext);
}
