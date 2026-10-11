import fs from "fs";
import os from "os";
import path from "path";
import { chacha20poly1305 } from "@noble/ciphers/chacha";
// eslint-disable-next-line @typescript-eslint/no-var-requires
const bplist = require("bplist-parser");

// Since macOS 14.4 the Find My caches are binary plists of the form
// { encryptedData: nonce(12) | ciphertext | tag(16), signature }, encrypted with
// ChaCha20-Poly1305. The symmetric keys live in the data-protection keychain
// (FMIPDataManager / FMFDataManager) and are exported once by findmy-key/keydump.
export const findMyKeyDir = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "bluebubbles-server",
    "findmy-keys"
);

export type FindMyKeyType = "FMIPDataManager" | "FMFDataManager";

const keyCache: Partial<Record<FindMyKeyType, Buffer>> = {};

export const loadFindMyKey = (type: FindMyKeyType): Buffer | null => {
    if (keyCache[type]) return keyCache[type];

    const keyPath = path.join(findMyKeyDir, `${type}.plist`);
    if (!fs.existsSync(keyPath)) return null;

    const items = bplist.parseBuffer(fs.readFileSync(keyPath))[0];
    const inner = bplist.parseBuffer(items[0].data)[0];
    const key: Buffer = inner?.symmetricKey?.key?.data;
    if (!Buffer.isBuffer(key) || key.length !== 32) return null;

    keyCache[type] = key;
    return key;
};

const parsePayload = (data: Buffer): any => {
    if (data.subarray(0, 6).toString() === "bplist") {
        return bplist.parseBuffer(data)[0];
    }

    return JSON.parse(data.toString("utf-8"));
};

/**
 * Reads a Find My cache file, decrypting it first if it uses the macOS 14.4+ format.
 * Returns null if the file is missing or cannot be decrypted.
 */
export const readFindMyCacheFile = (filePath: string, keyType: FindMyKeyType): any => {
    if (!fs.existsSync(filePath)) return null;

    const raw = fs.readFileSync(filePath);
    if (raw.subarray(0, 6).toString() !== "bplist") {
        // Pre-14.4 caches are plain JSON
        return JSON.parse(raw.toString("utf-8"));
    }

    const wrapper = bplist.parseBuffer(raw)[0];
    const encrypted: Buffer = wrapper?.encryptedData;
    if (!Buffer.isBuffer(encrypted)) return wrapper;

    const key = loadFindMyKey(keyType);
    if (!key) throw new Error(`Find My key ${keyType} has not been exported`);

    // Electron's BoringSSL has no chacha20-poly1305 cipher, so use a pure-JS AEAD.
    // noble expects ciphertext with the 16-byte tag appended, which is the on-disk layout.
    const nonce = encrypted.subarray(0, 12);
    const sealed = encrypted.subarray(12);
    const plaintext = chacha20poly1305(new Uint8Array(key), new Uint8Array(nonce)).decrypt(new Uint8Array(sealed));
    return parsePayload(Buffer.from(plaintext));
};
