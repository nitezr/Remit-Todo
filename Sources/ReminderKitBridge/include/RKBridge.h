#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const RKBridgeErrorDomain;

/// Writes the Apple Reminders metadata EventKit has no API for -- tags, sections and list groups --
/// through Apple's private ReminderKit framework, the framework Reminders.app itself is built on.
///
/// Every call is a straight port of a write RemCTL's `remctl-private.m` already performs and has
/// verified against live Reminders data, down to the selectors and argument values. Nothing here
/// touches SQLite: ReminderKit hands the change to `remindd`, which owns sync and schema.
///
/// Calls block on an XPC round trip to `remindd`, so call them off the main thread. Identifiers
/// are ReminderKit UUID strings, which are the same values EventKit exposes as
/// `calendarItemIdentifier` and `calendarIdentifier`.
@interface RKBridge : NSObject

/// False when ReminderKit cannot be loaded or no longer has the classes these writes need.
@property (class, readonly) BOOL isAvailable;

/// Replaces the reminder's entire tag set. An empty array clears every tag.
+ (BOOL)setTags:(NSArray<NSString *> *)tags forReminder:(NSString *)reminderID error:(NSError **)error;

/// Creates a section at the end of the list. `existingSectionIDs` must be the list's current
/// sections in order: ReminderKit stores ordering as one array, so omitting any would drop them
/// from Reminders' section order. Returns the new section's identifier.
+ (nullable NSString *)createSectionNamed:(NSString *)name
                                   inList:(NSString *)listID
                       existingSectionIDs:(NSArray<NSString *> *)existingSectionIDs
                                    error:(NSError **)error;

+ (BOOL)renameSection:(NSString *)sectionID to:(NSString *)name error:(NSError **)error;

/// Removes the section. Its reminders stay in the list, unsectioned.
+ (BOOL)deleteSection:(NSString *)sectionID error:(NSError **)error;

/// Moves a reminder into `sectionID`, or out of `previousSectionID` into no section when
/// `sectionID` is nil.
+ (BOOL)moveReminder:(NSString *)reminderID
           toSection:(nullable NSString *)sectionID
      leavingSection:(nullable NSString *)previousSectionID
               error:(NSError **)error;

/// Puts a list inside a Reminders group, or back at top level when `groupID` is nil.
+ (BOOL)setGroup:(nullable NSString *)groupID forList:(NSString *)listID error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
