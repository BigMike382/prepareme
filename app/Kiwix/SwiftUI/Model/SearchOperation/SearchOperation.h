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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SearchOperation : NSOperation

@property (nonatomic, strong) NSString *searchText;
/// PrepareMe: what was typed, when searchText is PrepareMeQuestionWords' words for it (2026-10-22). Title search looks
/// for it first, as typed, so a page typed by its title is found; searchText by default.
@property (nonatomic, strong) NSString *typedText;
@property (nonatomic, assign) BOOL extractMatchingSnippet;
/// PrepareMe: how many results, from the first, are only the closest pages: every result when no page held every word,
/// or the guides when only other libraries' pages did (SearchOperation.swift, addClosest); 0 when none are
@property (nonatomic, assign) NSInteger closestCount;
/// PrepareMe: how many results, from the first, are meaning search's section (SearchOperation.swift, addMeaning); the
/// closest pages, when there are any, follow it; 0 when there's no section
@property (nonatomic, assign) NSInteger meaningCount;
/// PrepareMe: the guides library, whose closest pages go first when only other libraries' pages hold every word
/// (PrepareMeSearchOrder.dailyID, set by SearchOperation.prepareMe; a test's own library in the tests); nil: none
@property (nonatomic, strong, nullable) NSUUID *guidesID;
@property (nonatomic, strong) NSMutableSet *foundURLs;
@property (nonatomic, nullable) NSURL *spellCacheDir;
@property (nonatomic, strong) NSSet *zimFileIDs;
@property (nonatomic, strong) NSMutableOrderedSet *results NS_REFINED_FOR_SWIFT;
@property (nonatomic, strong) NSMutableOrderedSet *corrections NS_REFINED_FOR_SWIFT;

- (id)initWithSearchText:(NSString *)searchText zimFileIDs:(NSSet *)zimFileIDs withSpellingCacheDir: (NSURL *_Nullable) spellCacheDir;
- (void)performSearch;
- (void) addSpellingCorrections NS_REFINED_FOR_SWIFT;

@end

NS_ASSUME_NONNULL_END
