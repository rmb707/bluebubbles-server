// Injected into FindMy.app (which can already read its own cache keys) to export
// the FMIPDataManager / FMFDataManager keychain items, so the BlueBubbles server
// can decrypt ~/Library/Caches/com.apple.findmy.* on macOS 14.4+.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static void dump(NSString *service, NSString *dir) {
    NSDictionary *q = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecUseDataProtectionKeychain: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    NSString *path = [dir stringByAppendingPathComponent:[service stringByAppendingString:@".result"]];
    if (st != errSecSuccess) {
        [[NSString stringWithFormat:@"status=%d", (int)st] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    NSArray *items = (__bridge_transfer NSArray *)result;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in items) {
        NSData *v = it[(__bridge id)kSecValueData];
        [out addObject:@{ @"account": it[(__bridge id)kSecAttrAccount] ?: @"",
                          @"group": it[(__bridge id)kSecAttrAccessGroup] ?: @"",
                          @"data": v ?: [NSData data] }];
    }
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:out format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [plist writeToFile:path atomically:YES];
}

__attribute__((constructor)) static void run(void) {
    NSString *dir = NSTemporaryDirectory();
    dump(@"FMIPDataManager", dir);
    dump(@"FMFDataManager", dir);
    [@"done" writeToFile:[dir stringByAppendingPathComponent:@"keydump.done"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
