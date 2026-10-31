#pragma once
#import <Foundation/Foundation.h>
// Update only owned keys. Preserve unrelated settings/comments and refuse unreadable files.
BOOL dm_settings_env_write(NSString *path, NSDictionary<NSString *,NSString *> *changes, NSError **error);
