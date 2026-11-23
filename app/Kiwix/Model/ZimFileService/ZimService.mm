// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#include <unordered_map>
#include <filesystem>
#include <sys/stat.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "kiwix/book.h"
#include "kiwix/kiwix_config.h"
#include "zim/archive.h"
#include "zim/entry.h"
#include "zim/error.h"
#include "zim/item.h"
#include "zim/search.h"
#include "zim/suggestion.h"
#include "PrepareMeTitleIndex.h"
#include "kiwix/spelling_correction.h"
#pragma clang diagnostic pop

#import "ZimService.h"
#import "ZimFileMetaData.h"
#import "xapian.h"

@interface ZimService ()

@property (assign) std::unordered_map<std::string, zim::Archive> *archives; // (NSUUID_c: Archive)
@property (strong) NSMutableDictionary *fileURLs; // [NSUUID: URL]
// PrepareMe: which file each cached archive was opened from, so a replaced file is opened again
@property (strong) NSMutableDictionary *fileStamps; // [NSUUID: NSString]
@property (strong) NSMutableSet *reopenedIDs; // [NSUUID], since the last takeReopenedIDs
// PrepareMe: the URL whose file access each open archive holds, given back when it is replaced or closed
@property (strong) NSMutableDictionary *grants; // [NSUUID: NSURL]
@property (strong) NSObject *archivesLock; // guards self.archives against search, which reads it off the ZimActor
// PrepareMe: each open archive's title searcher, its index opened with the archive (see openSearchIndexes)
@property (assign) std::unordered_map<std::string, std::shared_ptr<PrepareMeTitleIndex>> *titleSearchers;
// PrepareMe: libraries whose spelling index couldn't be built this launch, not tried again until the next
@property (strong) NSMutableSet *spellingFailedIDs; // [NSUUID]

@end

/// PrepareMe: libzim opens a library's search indexes by its file name (libzim src/tools.cpp, getDbFromAccessInfo),
/// the title index afresh for every new title searcher and the full-text index on its first use. One opened after
/// the file was replaced reads the new file at the old one's offsets: a crash, or no results (FINDINGS F-044). Both
/// are opened here, right after the archive itself, and kept with it, so they read the file it was opened from.
static void openSearchIndexes(const zim::Archive &archive, PrepareMeTitleIndex &titles) {
    try {
        std::lock_guard<std::mutex> locked(titles.lock);
        titles.searcher.suggest("a");
    } catch (std::exception &e) {
        NSLog(@"title index: %s", e.what());
    } catch (...) { // Xapian's errors aren't std::exceptions; insertIntoArchives's second stamp decides what follows
        NSLog(@"title index: an error that isn't a std::exception");
    }
    try {
        if (archive.hasFulltextIndex()) {
            zim::Searcher(archive).search(zim::Query("a"));
        }
    } catch (std::exception &e) {
        NSLog(@"full-text index: %s", e.what());
    } catch (...) {
        NSLog(@"full-text index: an error that isn't a std::exception");
    }
}

@implementation ZimService

#pragma mark - init

- (instancetype)init {
    self = [super init];
    if (self) {
        // 16*1024*1024
        // as of:
        // https://github.com/kiwix/libkiwix/issues/1265#issuecomment-3817993025
        zim::setClusterCacheMaxSize(16777216);
        self.archives = new std::unordered_map<std::string, zim::Archive>();
        self.fileURLs = [[NSMutableDictionary alloc] init];
        self.fileStamps = [[NSMutableDictionary alloc] init];
        self.reopenedIDs = [[NSMutableSet alloc] init];
        self.grants = [[NSMutableDictionary alloc] init];
        self.archivesLock = [[NSObject alloc] init];
        self.titleSearchers = new std::unordered_map<std::string, std::shared_ptr<PrepareMeTitleIndex>>();
        self.spellingFailedIDs = [[NSMutableSet alloc] init];
        self.libzimVersion = [[NSString alloc] initWithUTF8String:LIBZIM_VERSION];
        self.libkiwixVersion = [[NSString alloc] initWithUTF8String:LIBKIWIX_VERSION];
    }
    return self;
}

+ (ZimService *)sharedInstance {
    static ZimService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[ZimService alloc] init];
    });
    return sharedInstance;
}

- (void)dealloc {
    delete self.archives;
    delete self.titleSearchers;
    for (NSUUID *zimFileID in self.grants) { // PrepareMe: the URLs access was taken for, not the latest stored
        [self.grants[zimFileID] stopAccessingSecurityScopedResource];
    }
}

#pragma mark - Reader Management

- (void)store:(NSURL *)url with:(NSUUID *)zimFileID {
    try {
        // if url does not ends with "zim", skip it
        NSString *pathExtension = [[url pathExtension] lowercaseString];
        if (![pathExtension isEqualToString:@"zim"]) {
            return;
        }
        self.fileURLs[zimFileID] = url;
        // PrepareMe: if the file was replaced since its archive was opened, open the new file and swap it in.
        // A file that can't be read now (missing, not yet downloaded) or opened keeps the old archive.
        NSString *opened = self.fileStamps[zimFileID];
        NSString *now = opened == nil ? nil : [ZimService stampFor:url];
        if (now != nil && ![now isEqualToString:opened]) {
            NSLog(@"reopening replaced zim file: %@", zimFileID.UUIDString);
            if ([self insertIntoArchives:url with:zimFileID]) {
                [self.reopenedIDs addObject:zimFileID];
            }
        }
    } catch (std::exception) {
        NSLog(@"Error opening zim file.");
    }
}

/// PrepareMe: the file's device, inode, size and modification time, or nil if it can't be read.
+ (NSString *_Nullable)stampFor:(NSURL *_Nonnull)url {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    struct stat info;
    int failed = stat([url fileSystemRepresentation], &info);
    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }
    if (failed != 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"%d:%llu:%lld:%ld.%09ld", info.st_dev, (unsigned long long)info.st_ino,
            (long long)info.st_size, (long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec];
}

/// PrepareMe: the libraries reopened since the last call, so their open tabs can be reloaded.
- (NSArray *)takeReopenedIDs {
    NSArray *ids = [self.reopenedIDs allObjects];
    [self.reopenedIDs removeAllObjects];
    return ids;
}

- (NSUUID *_Nullable)open:(NSUUID *)zimFileID {
    if ([self archiveBy:zimFileID] == nil) {
        return nil;
    }
    return zimFileID;
}

- (void)close:(NSUUID *)zimFileID {
    @synchronized (self.archivesLock) {
        self.archives->erase([self zimfileID_C: zimFileID]);
        self.titleSearchers->erase([self zimfileID_C: zimFileID]);
    }
    [self.fileStamps removeObjectForKey:zimFileID];
    [self.grants[zimFileID] stopAccessingSecurityScopedResource]; // PrepareMe: the URL access was taken for
    [self.grants removeObjectForKey:zimFileID];
    [self.fileURLs removeObjectForKey:zimFileID];
}

- (NSArray *)getReaderIdentifiers {
    return [self.fileURLs allKeys];
}

- (nonnull void *) getTitleSearchers {
    return self.titleSearchers;
}

- (nonnull void *) getArchives {
    NSLog(@"archives: %zu",  self.archives->size());
    return self.archives;
}

# pragma mark - Spelling
- (SpellingsDBWrapper *_Nullable)spellingsDBFor:(NSUUID *)zimFileID cachePath:(NSString *)contentPath {
    
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) {
        NSLog(@"cannot find ZIM by ID: %@ (%@)", zimFileID.UUIDString, contentPath);
        return nil;
    }
    @synchronized (self) {
        // PrepareMe (2026-11-12): a library that failed once isn't built again at every search this launch
        if ([self.spellingFailedIDs containsObject:zimFileID]) { return nil; }
        // PrepareMe (2026-11-14, F-115): nor at a later launch: a large library's failed build was about a minute each
        // time. A new copy drops the mark with its index (SpellingIndex.forget), so that copy is tried.
        NSString *failedMark = [contentPath stringByAppendingPathComponent:
            [zimFileID.UUIDString.lowercaseString stringByAppendingString:@".spellingsdb.v0.1.failed"]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:failedMark]) {
            [self.spellingFailedIDs addObject:zimFileID];
            return nil;
        }
        try {
            NSLog(@"createSpellingIndex for:%@, in: %@", zimFileID.UUIDString, contentPath);
            // this should be safe for utf-8, it comes from swift URL.path(percentEncoded=True)
            std::filesystem::path path = std::filesystem::path([contentPath cStringUsingEncoding: NSUTF8StringEncoding]);
            auto db = std::make_unique<kiwix::SpellingsDB>(*archive, path);
            SpellingsDBWrapper *wrapper = [[SpellingsDBWrapper alloc] initWithDB: std::move(db)];
            return wrapper;
        } catch (const std::exception &e) {
            NSLog(@"create spelling index exception: %s", e.what());
        } catch (const Xapian::Error &e) {
            // PrepareMe (2026-11-12): every Xapian error, not only DatabaseError: a title over 255 bytes throws
            // InvalidArgumentError ("Key too long") at the commit, which reached Swift and aborted the app at launch
            NSLog(@"create spelling index exception: %s", e.get_description().c_str());
        } catch (...) {
            NSLog(@"create spelling index: an error that isn't a std::exception or a Xapian::Error");
        }
        [self.spellingFailedIDs addObject:zimFileID];
        [[NSData data] writeToFile:failedMark atomically:YES];
        return nil;
    }
}

- (void) createSpellingIndex:(NSUUID *)zimFileID cachePath:(NSString *)contentPath {
    [self spellingsDBFor:zimFileID cachePath:contentPath];
}

# pragma mark - Metadata

+ (ZimFileMetaData *_Nullable)getMetaDataWithFileURL:(NSURL *)url {
    ZimFileMetaData *metaData = nil;
    [url startAccessingSecurityScopedResource];
    try {
        kiwix::Book book = kiwix::Book();
        book.update(zim::Archive([url fileSystemRepresentation]));
        // since we do have the ZIM file locally, we wan't the favicon as well
        metaData = [[ZimFileMetaData alloc] initWithBook: &book fetchFavicon: true];
    } catch (std::exception e) {
        [url stopAccessingSecurityScopedResource];
        return nil;
    }
    [url stopAccessingSecurityScopedResource];
    return metaData;
}

# pragma mark - URL Handling

- (NSURL *)getFileURL:(NSUUID *)zimFileID {
    return self.fileURLs[zimFileID];
}

- (NSString *_Nullable) getRedirectedPath:(NSUUID *_Nonnull)zimFileID contentPath:(NSString *_Nonnull)contentPath {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return nil; }
    try {
        const char *_Nullable contentPathC = [contentPath cStringUsingEncoding:NSUTF8StringEncoding];
        if (contentPathC != nil) {
            zim::Item item = archive->getEntryByPath(contentPathC).getRedirect();
            return [NSString stringWithUTF8String: item.getPath().c_str()];
        } else {
            return nil;
        }
    } catch (std::exception) {
        return nil;
    }
}

- (NSString *_Nullable)getMainPagePath:(NSUUID *)zimFileID {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return nil; }
    try {
        zim::Entry entry = archive->getMainEntry();
        zim::Item item = entry.getItem(entry.isRedirect());
        NSString *_Nullable pagePath = [NSString stringWithCString:item.getPath().c_str() encoding:NSUTF8StringEncoding];
        return pagePath;
    } catch (std::exception) {
        return nil;
    }
}

- (NSString *_Nullable)getRandomPagePath:(NSUUID *)zimFileID {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return nil; }
    try {
        zim::Entry entry = archive->getRandomEntry();
        zim::Item item = entry.getItem(entry.isRedirect());
        NSString *_Nullable pagePath = [NSString stringWithCString:item.getPath().c_str() encoding:NSUTF8StringEncoding];
        return pagePath;
    } catch (std::exception) {
        return nil;
    }
}

- (NSNumber* _Nullable)getContentSize:(NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath:contentPath];
        return [NSNumber numberWithUnsignedLongLong:item.getSize()];
    } catch (std::exception) {
        return nil;
    }
}

- (NSDictionary *)getMetaData:(NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath:contentPath];
        NSDate *modificationDate = [self getModificationDateOf: zimFileID];
        if(modificationDate == nil) {
            return nil;
        }
        return @{
            @"mime": [NSString stringWithUTF8String:item.getMimetype().c_str()],
            @"size": [NSNumber numberWithUnsignedLongLong:item.getSize()],
            @"title": [NSString stringWithUTF8String:item.getTitle().c_str()],
            @"zimFileDate": modificationDate
        };
    } catch (zim::EntryNotFound(EntryNotFound)) {
        return nil;
    } catch (std::exception) {
        return nil;
    }
}

- (NSDictionary *)getContent:(NSUUID *)zimFileID contentPath:(NSString *)contentPath
                       start:(NSUInteger)start end:(NSUInteger)end {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath:contentPath];
        zim::Blob blob;
        if (start == 0 && end == 0) {
            blob = item.getData();
        } else if (end == 0) {
            blob = item.getData(start, item.getSize() - start);
        } else {
            blob = item.getData(start, fmin(item.getSize() - start, end - start + 1));
        }
        return @{
            @"data": [NSData dataWithBytes: blob.data() length:blob.size()],
            @"start": [NSNumber numberWithUnsignedLongLong:start],
            @"end": [NSNumber numberWithUnsignedLongLong:start + blob.size() - 1]
        };
    } catch (std::exception) {
        return nil;
    }
}

- (NSDictionary *_Nullable) getDirectAccess: (NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath: contentPath];
        zim::ItemDataDirectAccessInfo info = item.getDirectAccessInformation();
        return @{
            @"path": [NSString stringWithUTF8String: info.filename.c_str()],
            @"offset": [NSNumber numberWithUnsignedLong: info.offset]
        };
    } catch(std::exception) {
        return nil;
    }
}

# pragma mark - ZIM integrity check
- (Boolean) checkIntegrity: (NSUUID *_Nonnull) zimFileID {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return false; }
    return archive->checkIntegrity(zim::IntegrityCheck::CHECKSUM);
}

+ (NSString *_Nullable) problemWithFileAt: (NSURL *_Nonnull)url expecting: (NSUUID *_Nonnull)zimFileID {
    std::string expected = [[[zimFileID UUIDString] lowercaseString] cStringUsingEncoding:NSUTF8StringEncoding];
    try {
        zim::Archive archive = zim::Archive([url fileSystemRepresentation]);
        if (std::string(archive.getUuid()) != expected) {
            return @"it carries another library's ID";
        }
        if (!archive.checkIntegrity(zim::IntegrityCheck::CHECKSUM)) {
            return @"its own checksum doesn't match its contents";
        }
        return nil;
    } catch (std::exception &e) {
        return @"it can't be opened as a library";
    } catch (...) {
        return @"it can't be opened as a library";
    }
}

# pragma mark - private

/// Converts the UUID to a C representation
- (std::string) zimfileID_C: (NSUUID *_Nonnull) zimFileID {
    // should be safe for utf-8 encoding
    return [[[zimFileID UUIDString] lowercaseString] cStringUsingEncoding:NSUTF8StringEncoding];
}

/// Find or insert and return the archive by zimFileID
- (zim::Archive *_Nullable) archiveBy: (NSUUID *_Nonnull) zimFileID {
    zim::Archive *found = [self findArchiveBy:zimFileID];
    if(found == nil) {
        NSURL *url = self.fileURLs[zimFileID];
        if (url == nil) {
            return nil;
        }
        [self insertIntoArchives:url with:zimFileID];
        return [self findArchiveBy: zimFileID];
    } else {
        return found;
    }
}

/// Only find (no insertion of) the archive by zimFileID
- (zim::Archive *_Nullable) findArchiveBy: (NSUUID *_Nonnull) zimFileID {
    std::string zimFileID_C = [self zimfileID_C: zimFileID];
    auto found = self.archives->find(zimFileID_C);
    if (found == self.archives->end()) {
        return nil;
    }
    return &(found->second);
}

/// PrepareMe: opens the file's archive and its search indexes and swaps them in. The file is stamped before the
/// archive opens and again once its indexes have, and opened again (3 tries in all) when the two differ, so a file
/// replaced mid-open never leaves the archive with the next file's index (assessment B9; FINDINGS F-044). An open
/// archive holds the file access taken for it, and the access held for the copy it replaces is given back: access
/// never given back eventually stops the app opening files until it is restarted (Apple). On failure the old archive
/// and its access stay, and the next check tries again. A file whose ID isn't the library's (a stray copy of another
/// library at its path) is never taken for it.
- (BOOL) insertIntoArchives: (NSURL *_Nonnull) url with: (NSUUID *_Nonnull) zimFileID {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    for (int attempt = 1; attempt <= 3; attempt++) {
        try {
            NSString *stamp = [ZimService stampFor:url];
            zim::Archive archive = zim::Archive([url fileSystemRepresentation]); // takes the longest time
            if (std::string(archive.getUuid()) != [self zimfileID_C:zimFileID]) {
                NSLog(@"not opened: the file at %@'s path carries another ID", zimFileID.UUIDString);
                break;
            }
            if (self.afterArchiveOpenForTests) {
                self.afterArchiveOpenForTests();
            }
            auto titles = std::make_shared<PrepareMeTitleIndex>(archive);
            openSearchIndexes(archive, *titles);
            NSString *after = [ZimService stampFor:url];
            if (stamp == nil ? after != nil : ![stamp isEqualToString:after]) {
                NSLog(@"zim file replaced while it opened, opening it again: %@", zimFileID.UUIDString);
                continue;
            }
            @synchronized (self.archivesLock) { // replaces a reopened file's archive in one step
                self.archives->insert_or_assign(std::string(archive.getUuid()), archive);
                self.titleSearchers->insert_or_assign(std::string(archive.getUuid()), titles);
            }
            if (stamp != nil) {
                self.fileStamps[zimFileID] = stamp;
            } else {
                [self.fileStamps removeObjectForKey:zimFileID]; // never one from an older copy, reopened at every check
            }
            NSURL *replaced = self.grants[zimFileID];
            if (scoped) {
                self.grants[zimFileID] = url;
            } else {
                [self.grants removeObjectForKey:zimFileID];
            }
            [replaced stopAccessingSecurityScopedResource];
            return YES;
        } catch (std::exception) {
            NSLog(@"cannot insert archive with: %@, %@", url.absoluteString, zimFileID.UUIDString);
            break;
        }
    }
    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }
    return NO;
}

- (zim::Item) itemIn: (NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    if ([contentPath hasPrefix:@"/"]) {
        contentPath = [contentPath substringFromIndex:1];
    }
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { throw std::exception(); }
    
    const char *_Nullable contentPath_c = [contentPath cStringUsingEncoding:NSUTF8StringEncoding];
    if (contentPath_c == nil) {
        throw std::exception();
    }
    zim::Entry entry = archive->getEntryByPath(contentPath_c);
    return entry.getItem(entry.isRedirect());
}

/// get the modification date of the ZIM file itself
- (NSDate *_Nullable) getModificationDateOf: (NSUUID *_Nonnull) zimFileID {
    NSURL *fileURL = [self getFileURL: zimFileID];
    if (fileURL == nil) {
        return nil;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:[fileURL path] error:&error];
    if (fileAttributes) {
        return [fileAttributes objectForKey:NSFileModificationDate];
    } else {
        NSLog(@"Error retrieving file modification date: %@", [error localizedDescription]);
        return nil;
    }
}

@end
