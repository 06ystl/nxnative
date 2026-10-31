#include "settings_store_mac.h"
BOOL dm_settings_env_write(NSString *path, NSDictionary<NSString *,NSString *> *changes, NSError **error) {
    NSError *readError=nil;
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!text && [NSFileManager.defaultManager fileExistsAtPath:path]) {if(error)*error=readError;return NO;}
    NSMutableSet *written=[NSMutableSet set];NSMutableArray *lines=[NSMutableArray array];
    for (NSString *raw in [(text ?: @"") componentsSeparatedByString:@"\n"]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange eq=[line rangeOfString:@"="];NSString *key=nil;
        if (![line hasPrefix:@"#"] && eq.location!=NSNotFound)
            key=[[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key && changes[key]) {
            if (![written containsObject:key]) [lines addObject:[NSString stringWithFormat:@"%@=%@",key,changes[key]]];
            [written addObject:key];
        } else [lines addObject:raw];
    }
    while (lines.count && ![lines.lastObject length]) [lines removeLastObject];
    for (NSString *key in [changes.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (![written containsObject:key]) [lines addObject:[NSString stringWithFormat:@"%@=%@",key,changes[key]]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    return [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}
