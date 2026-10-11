# Find My cache key export

Since macOS 14.4 the Find My caches (`~/Library/Caches/com.apple.findmy.fmipcore/*.data`,
`com.apple.findmy.fmfcore/*.data`) are ChaCha20-Poly1305 encrypted. The keys
(`FMIPDataManager`, `FMFDataManager`) sit in the data-protection keychain and are only
readable by Find My itself.

`keydump.m` is injected into FindMy.app (same mechanism the Private API helper uses for
Messages: SIP disabled + library validation disabled) and writes both keys into Find My's
sandbox tmp dir. Move them to
`~/Library/Application Support/bluebubbles-server/findmy-keys/` (chmod 600). The server
(`src/server/api/lib/findmy/cacheCrypto.ts`) decrypts the caches with them.

```sh
clang -arch arm64e -arch arm64 -dynamiclib -fobjc-arc -framework Foundation -framework Security -o keydump.dylib keydump.m
codesign -f -s - keydump.dylib
DYLD_INSERT_LIBRARIES=$PWD/keydump.dylib /System/Applications/FindMy.app/Contents/MacOS/FindMy
# results: ~/Library/Containers/com.apple.findmy/Data/tmp/{FMIPDataManager,FMFDataManager}.result
```

Keys only need exporting once (until the Find My keychain items are regenerated).
