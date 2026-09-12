#import "RKBridge.h"
#include <dlfcn.h>

NSErrorDomain const RKBridgeErrorDomain = @"RKBridge";

// ReminderKit ships no headers. These declarations are copied from remctl-private.m, where each one
// is exercised against the real framework. Classes are looked up with NSClassFromString rather than
// linked, so a macOS release that moves or drops one surfaces as an error from these methods instead
// of Remit failing to launch.

@protocol RKObjectIDClass <NSObject>
+ (id)objectIDWithURL:(NSURL *)url;
@end

@protocol RKObjectID <NSObject>
- (NSUUID *)uuid;
@end

@protocol RKStore <NSObject>
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchPrimaryActiveCloudKitAccountWithError:(NSError **)error;
- (id)fetchDefaultAccountWithError:(NSError **)error;
@end

@protocol RKSaveRequest <NSObject>
- (id)initWithStore:(id)store;
- (id)updateReminder:(id)reminder;
- (id)updateList:(id)list;
- (id)updateListSection:(id)section;
- (id)addListSectionWithDisplayName:(NSString *)name toListSectionContextChangeItem:(id)context;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end

@protocol RKReminder <NSObject>
- (id)list;
@end

@protocol RKOwned <NSObject>
- (id)account;
- (id)remObjectID;
@end

@protocol RKReminderChangeItem <NSObject>
- (id)hashtagContext;
@end

@protocol RKHashtagContext <NSObject>
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
- (void)removeAllHashtags;
@end

@protocol RKListChangeItem <NSObject>
- (id)sectionsContextChangeItem;
- (void)setParentOwnerID:(id)objectID;
- (void)setParentSubContainerID:(id)objectID;
@end

@protocol RKSectionContext <NSObject>
- (void)setShouldUpdateSectionsOrdering:(BOOL)update;
- (void)setUnsavedMembershipsOfRemindersInSections:(id)memberships;
- (void)setUnsavedSectionIDsOrdering:(NSArray *)ordering;
@end

@protocol RKSectionChangeItem <NSObject>
- (id)remObjectID;
- (void)setDisplayName:(NSString *)displayName;
- (void)removeFromList;
@end

@protocol RKMembership <NSObject>
- (id)initWithMemberIdentifier:(NSUUID *)memberIdentifier
               groupIdentifier:(NSUUID *)groupIdentifier
                    isObsolete:(BOOL)isObsolete
                    modifiedOn:(NSDate *)modifiedOn;
@end

@protocol RKMemberships <NSObject>
- (id)initWithMemberships:(NSArray *)memberships;
@end

#pragma mark - Helpers

static BOOL RKLoad(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW | RTLD_GLOBAL);
        loaded = handle != NULL
            && NSClassFromString(@"REMStore") != nil
            && NSClassFromString(@"REMSaveRequest") != nil
            && NSClassFromString(@"REMObjectID") != nil;
    });
    return loaded;
}

static BOOL RKFail(NSError **error, NSError *underlying, NSString *message) {
    if (error) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        NSString *detail = underlying.localizedDescription;
        info[NSLocalizedDescriptionKey] = detail.length ? [NSString stringWithFormat:@"%@ (%@)", message, detail] : message;
        if (underlying) info[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:RKBridgeErrorDomain code:1 userInfo:info];
    }
    return NO;
}

static BOOL RKFailException(NSError **error, NSException *exception) {
    NSString *reason = exception.reason ?: exception.name ?: @"unknown exception";
    return RKFail(error, nil, [NSString stringWithFormat:@"Reminders rejected the change: %@", reason]);
}

static BOOL RKUnavailable(NSError **error) {
    return RKFail(error, nil, @"ReminderKit is not available on this version of macOS, so tags, sections and groups cannot be changed.");
}

static id RKObjectID(NSString *entity, NSString *identifier) {
    if (identifier.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://%@/%@", entity, identifier]];
    if (!url) return nil;
    Class<RKObjectIDClass> cls = (Class<RKObjectIDClass>)NSClassFromString(@"REMObjectID");
    return [cls objectIDWithURL:url];
}

static id<RKStore> RKNewStore(void) {
    return (id<RKStore>)[NSClassFromString(@"REMStore") new];
}

static id<RKSaveRequest> RKNewSave(id<RKStore> store) {
    return [(id<RKSaveRequest>)[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
}

/// remctl-private.m's fetchWritableCloudKitAccount: the primary CloudKit account, falling back to
/// the default account only when that is itself a CloudKit account.
static id RKWritableAccount(id<RKStore> store, NSError **error) {
    id account = nil;
    if ([store respondsToSelector:@selector(fetchPrimaryActiveCloudKitAccountWithError:)]) {
        account = [store fetchPrimaryActiveCloudKitAccountWithError:error];
    }
    if (account) return account;
    if ([store respondsToSelector:@selector(fetchDefaultAccountWithError:)]) {
        account = [store fetchDefaultAccountWithError:error];
        NSString *className = account ? NSStringFromClass([account class]) : @"";
        if ([className rangeOfString:@"CloudKit" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            account = nil;
        }
    }
    return account;
}

static NSString *RKTagName(NSString *raw) {
    NSString *name = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([name hasPrefix:@"#"]) name = [name substringFromIndex:1];
    return name;
}

#pragma mark - Bridge

@implementation RKBridge

+ (BOOL)isAvailable {
    return RKLoad();
}

+ (BOOL)setTags:(NSArray<NSString *> *)tags forReminder:(NSString *)reminderID error:(NSError **)error {
    if (!RKLoad()) return RKUnavailable(error);
    @try {
        id objectID = RKObjectID(@"REMCDReminder", reminderID);
        if (!objectID) return RKFail(error, nil, @"Could not address that reminder in ReminderKit.");

        id<RKStore> store = RKNewStore();
        NSError *inner = nil;
        id reminder = [store fetchReminderWithObjectID:objectID error:&inner];
        if (!reminder) return RKFail(error, inner, @"That reminder could not be found in Reminders.");

        id<RKSaveRequest> save = RKNewSave(store);
        id<RKReminderChangeItem> change = [save updateReminder:reminder];
        id<RKHashtagContext> context = [change respondsToSelector:@selector(hashtagContext)] ? [change hashtagContext] : nil;
        if (![context respondsToSelector:@selector(removeAllHashtags)]
            || ![context respondsToSelector:@selector(addHashtagWithType:name:)]) {
            return RKFail(error, nil, @"This version of Reminders does not support editing tags.");
        }

        // remctl's set_tags: clear, then add each. Type 1 is an ordinary user tag.
        [context removeAllHashtags];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *raw in tags) {
            NSString *name = RKTagName(raw);
            if (name.length == 0 || [seen containsObject:name.lowercaseString]) continue;
            [seen addObject:name.lowercaseString];
            [context addHashtagWithType:1 name:name];
        }

        if (![save saveSynchronouslyWithError:&inner]) {
            return RKFail(error, inner, @"Reminders did not save the tag change.");
        }
        return YES;
    } @catch (NSException *exception) {
        return RKFailException(error, exception);
    }
}

+ (NSString *)createSectionNamed:(NSString *)name
                          inList:(NSString *)listID
              existingSectionIDs:(NSArray<NSString *> *)existingSectionIDs
                           error:(NSError **)error {
    if (!RKLoad()) { RKUnavailable(error); return nil; }
    @try {
        id listObjectID = RKObjectID(@"REMCDList", listID);
        if (!listObjectID) { RKFail(error, nil, @"Could not address that list in ReminderKit."); return nil; }

        id<RKStore> store = RKNewStore();
        NSError *inner = nil;
        id list = [store fetchListWithObjectID:listObjectID error:&inner];
        if (!list) { RKFail(error, inner, @"That list could not be found in Reminders."); return nil; }

        id<RKSaveRequest> save = RKNewSave(store);
        id<RKListChangeItem> listChange = [save updateList:list];
        id<RKSectionContext> context = [listChange respondsToSelector:@selector(sectionsContextChangeItem)]
            ? [listChange sectionsContextChangeItem] : nil;
        if (![context respondsToSelector:@selector(setUnsavedSectionIDsOrdering:)]) {
            RKFail(error, nil, @"This version of Reminders does not support sections.");
            return nil;
        }

        id<RKSectionChangeItem> section = [save addListSectionWithDisplayName:name toListSectionContextChangeItem:context];
        id<RKObjectID> sectionObjectID = [section remObjectID];
        if (!sectionObjectID) { RKFail(error, nil, @"Reminders did not create the section."); return nil; }

        NSMutableArray *ordering = [NSMutableArray array];
        for (NSString *existing in existingSectionIDs) {
            id existingID = RKObjectID(@"REMCDListSection", existing);
            if (existingID) [ordering addObject:existingID];
        }
        [ordering addObject:sectionObjectID];
        [context setUnsavedSectionIDsOrdering:ordering];
        [context setShouldUpdateSectionsOrdering:YES];

        if (![save saveSynchronouslyWithError:&inner]) {
            RKFail(error, inner, @"Reminders did not save the new section.");
            return nil;
        }
        return sectionObjectID.uuid.UUIDString;
    } @catch (NSException *exception) {
        RKFailException(error, exception);
        return nil;
    }
}

+ (BOOL)renameSection:(NSString *)sectionID to:(NSString *)name error:(NSError **)error {
    return [self changeSection:sectionID error:error apply:^BOOL(id<RKSectionChangeItem> change, NSError **inner) {
        if (![change respondsToSelector:@selector(setDisplayName:)]) {
            return RKFail(inner, nil, @"This version of Reminders does not support renaming sections.");
        }
        [change setDisplayName:name];
        return YES;
    }];
}

+ (BOOL)deleteSection:(NSString *)sectionID error:(NSError **)error {
    return [self changeSection:sectionID error:error apply:^BOOL(id<RKSectionChangeItem> change, NSError **inner) {
        if (![change respondsToSelector:@selector(removeFromList)]) {
            return RKFail(inner, nil, @"This version of Reminders does not support deleting sections.");
        }
        [change removeFromList];
        return YES;
    }];
}

+ (BOOL)changeSection:(NSString *)sectionID
                error:(NSError **)error
                apply:(BOOL (^)(id<RKSectionChangeItem> change, NSError **error))apply {
    if (!RKLoad()) return RKUnavailable(error);
    @try {
        id objectID = RKObjectID(@"REMCDListSection", sectionID);
        if (!objectID) return RKFail(error, nil, @"Could not address that section in ReminderKit.");

        id<RKStore> store = RKNewStore();
        NSError *inner = nil;
        id section = [store fetchListSectionWithObjectID:objectID error:&inner];
        if (!section) return RKFail(error, inner, @"That section could not be found in Reminders.");

        id<RKSaveRequest> save = RKNewSave(store);
        id<RKSectionChangeItem> change = [save updateListSection:section];
        if (!change) return RKFail(error, nil, @"Reminders would not edit that section.");
        if (!apply(change, error)) return NO;

        if (![save saveSynchronouslyWithError:&inner]) {
            return RKFail(error, inner, @"Reminders did not save the section change.");
        }
        return YES;
    } @catch (NSException *exception) {
        return RKFailException(error, exception);
    }
}

+ (BOOL)moveReminder:(NSString *)reminderID
           toSection:(NSString *)sectionID
      leavingSection:(NSString *)previousSectionID
               error:(NSError **)error {
    if (sectionID.length == 0 && previousSectionID.length == 0) return YES;
    if (sectionID.length && [sectionID caseInsensitiveCompare:previousSectionID ?: @""] == NSOrderedSame) return YES;
    if (!RKLoad()) return RKUnavailable(error);
    @try {
        id<RKObjectID> reminderObjectID = RKObjectID(@"REMCDReminder", reminderID);
        if (!reminderObjectID) return RKFail(error, nil, @"Could not address that reminder in ReminderKit.");

        id<RKStore> store = RKNewStore();
        NSError *inner = nil;
        id reminder = [store fetchReminderWithObjectID:reminderObjectID error:&inner];
        if (!reminder) return RKFail(error, inner, @"That reminder could not be found in Reminders.");

        id<RKSaveRequest> save = RKNewSave(store);
        // remctl creates the reminder's change item before editing its list; kept for parity with
        // the path it has verified.
        [save updateReminder:reminder];

        id list = [(id<RKReminder>)reminder list];
        if (!list) return RKFail(error, nil, @"That reminder is not in a list.");
        id<RKListChangeItem> listChange = [save updateList:list];
        id<RKSectionContext> context = [listChange respondsToSelector:@selector(sectionsContextChangeItem)]
            ? [listChange sectionsContextChangeItem] : nil;
        if (![context respondsToSelector:@selector(setUnsavedMembershipsOfRemindersInSections:)]) {
            return RKFail(error, nil, @"This version of Reminders does not support sections.");
        }

        // Memberships are a merge log keyed by reminder. Joining a section is a live entry for it;
        // leaving one is an obsolete entry for the section being left.
        NSString *groupID = sectionID.length ? sectionID : previousSectionID;
        id<RKObjectID> groupObjectID = RKObjectID(@"REMCDListSection", groupID);
        if (!groupObjectID) return RKFail(error, nil, @"Could not address that section in ReminderKit.");
        if (sectionID.length) {
            id section = [store fetchListSectionWithObjectID:groupObjectID error:&inner];
            if (!section) return RKFail(error, inner, @"That section could not be found in Reminders.");
        }

        id membership = [(id<RKMembership>)[NSClassFromString(@"REMMembership") alloc]
            initWithMemberIdentifier:reminderObjectID.uuid
                     groupIdentifier:groupObjectID.uuid
                          isObsolete:(sectionID.length == 0)
                          modifiedOn:[NSDate date]];
        id memberships = [(id<RKMemberships>)[NSClassFromString(@"REMMemberships") alloc] initWithMemberships:@[membership]];
        if (!membership || !memberships) return RKFail(error, nil, @"This version of Reminders does not support section membership.");
        [context setUnsavedMembershipsOfRemindersInSections:memberships];

        if (![save saveSynchronouslyWithError:&inner]) {
            return RKFail(error, inner, @"Reminders did not save the section change.");
        }
        return YES;
    } @catch (NSException *exception) {
        return RKFailException(error, exception);
    }
}

+ (BOOL)setGroup:(NSString *)groupID forList:(NSString *)listID error:(NSError **)error {
    if (!RKLoad()) return RKUnavailable(error);
    @try {
        id listObjectID = RKObjectID(@"REMCDList", listID);
        if (!listObjectID) return RKFail(error, nil, @"Could not address that list in ReminderKit.");

        id<RKStore> store = RKNewStore();
        NSError *inner = nil;
        id list = [store fetchListWithObjectID:listObjectID error:&inner];
        if (!list) return RKFail(error, inner, @"That list could not be found in Reminders.");

        id groupObjectID = nil;
        id group = nil;
        if (groupID.length) {
            groupObjectID = RKObjectID(@"REMCDList", groupID);
            group = groupObjectID ? [store fetchListWithObjectID:groupObjectID error:&inner] : nil;
            if (!group) return RKFail(error, inner, @"That group could not be found in Reminders.");
        }

        id account = [list respondsToSelector:@selector(account)] ? [(id<RKOwned>)list account] : nil;
        if (!account && [group respondsToSelector:@selector(account)]) account = [(id<RKOwned>)group account];
        if (!account) account = RKWritableAccount(store, &inner);
        if (!account) return RKFail(error, inner, @"No active iCloud Reminders account was found.");

        id<RKSaveRequest> save = RKNewSave(store);
        id<RKListChangeItem> change = [save updateList:list];
        if (![change respondsToSelector:@selector(setParentSubContainerID:)]) {
            return RKFail(error, nil, @"This version of Reminders does not support list groups.");
        }
        if ([change respondsToSelector:@selector(setParentOwnerID:)]) {
            [change setParentOwnerID:[(id<RKOwned>)account remObjectID]];
        }
        [change setParentSubContainerID:groupObjectID];

        if (![save saveSynchronouslyWithError:&inner]) {
            return RKFail(error, inner, @"Reminders did not save the group change.");
        }
        return YES;
    } @catch (NSException *exception) {
        return RKFailException(error, exception);
    }
}

@end
