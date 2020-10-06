//
//  NCRoom.m
//  VideoCalls
//
//  Created by Ivan Sein on 12.07.17.
//  Copyright © 2017 struktur AG. All rights reserved.
//

#import "NCRoom.h"

#import "NCDatabaseManager.h"
#import "NCSettingsController.h"

NSString * const NCRoomObjectTypeFile           = @"file";
NSString * const NCRoomObjectTypeSharePassword  = @"share:password";

@implementation NCRoom

+ (instancetype)roomWithDictionary:(NSDictionary *)roomDict
{
    if (!roomDict) {
        return nil;
    }
    
    NCRoom *room = [[self alloc] init];
    room.roomId = [[roomDict objectForKey:@"id"] integerValue];
    room.token = [roomDict objectForKey:@"token"];
    room.type = (NCRoomType)[[roomDict objectForKey:@"type"] integerValue];
    room.count = [[roomDict objectForKey:@"count"] integerValue];
    room.hasPassword = [[roomDict objectForKey:@"hasPassword"] boolValue];
    room.participantType = (NCParticipantType)[[roomDict objectForKey:@"participantType"] integerValue];
    room.lastPing = [[roomDict objectForKey:@"lastPing"] integerValue];
    room.numGuests = [[roomDict objectForKey:@"numGuests"] integerValue];
    room.unreadMessages = [[roomDict objectForKey:@"unreadMessages"] integerValue];
    room.unreadMention = [[roomDict objectForKey:@"unreadMention"] boolValue];
    room.guestList = [roomDict objectForKey:@"guestList"];
    room.lastActivity = [[roomDict objectForKey:@"lastActivity"] integerValue];
    room.isFavorite = [[roomDict objectForKey:@"isFavorite"] boolValue];
    room.notificationLevel = (NCRoomNotificationLevel)[[roomDict objectForKey:@"notificationLevel"] integerValue];
    room.objectType = [roomDict objectForKey:@"objectType"];
    room.objectId = [roomDict objectForKey:@"objectId"];
    room.readOnlyState = (NCRoomReadOnlyState)[[roomDict objectForKey:@"readOnly"] integerValue];
    room.lobbyState = (NCRoomLobbyState)[[roomDict objectForKey:@"lobbyState"] integerValue];
    room.lobbyTimer = [[roomDict objectForKey:@"lobbyTimer"] integerValue];
    room.lastReadMessage = [[roomDict objectForKey:@"lastReadMessage"] integerValue];
    room.canStartCall = [[roomDict objectForKey:@"canStartCall"] boolValue];
    room.hasCall = [[roomDict objectForKey:@"hasCall"] boolValue];
    
    id name = [roomDict objectForKey:@"name"];
    if ([name isKindOfClass:[NSString class]]) {
        room.name = name;
    } else {
        room.name = [name stringValue];
    }
    
    id displayName = [roomDict objectForKey:@"displayName"];
    if ([displayName isKindOfClass:[NSString class]]) {
        room.displayName = displayName;
    } else {
        room.displayName = [displayName stringValue];
    }
    
    id participants = [roomDict objectForKey:@"participants"];
    if ([participants isKindOfClass:[NSDictionary class]]) {
        room.participants = (RLMArray<RLMString> *)[participants allKeys];
    }
    
    return room;
}

+ (instancetype)roomWithDictionary:(NSDictionary *)roomDict andAccountId:(NSString *)accountId
{
    NCRoom *room = [self roomWithDictionary:roomDict];
    if (room) {
        room.accountId = accountId;
        room.internalId = [NSString stringWithFormat:@"%@@%@", room.accountId, room.token];
    }
    
    return room;
}

+ (void)updateRoom:(NCRoom *)managedRoom withRoom:(NCRoom *)room
{
    managedRoom.name = room.name;
    managedRoom.displayName = room.displayName;
    managedRoom.type = room.type;
    managedRoom.count = room.count;
    managedRoom.hasPassword = room.hasPassword;
    managedRoom.participantType = room.participantType;
    managedRoom.lastPing = room.lastPing;
    managedRoom.numGuests = room.numGuests;
    managedRoom.unreadMessages = room.unreadMessages;
    managedRoom.unreadMention = room.unreadMention;
    managedRoom.guestList = room.guestList;
    managedRoom.participants = room.participants;
    managedRoom.lastActivity = room.lastActivity;
    managedRoom.lastMessageId = room.lastMessageId;
    managedRoom.isFavorite = room.isFavorite;
    managedRoom.notificationLevel = room.notificationLevel;
    managedRoom.objectType = room.objectType;
    managedRoom.objectId = room.objectId;
    managedRoom.readOnlyState = room.readOnlyState;
    managedRoom.lobbyState = room.lobbyState;
    managedRoom.lobbyTimer = room.lobbyTimer;
    managedRoom.lastReadMessage = room.lastReadMessage;
    managedRoom.canStartCall = room.canStartCall;
    managedRoom.hasCall = room.hasCall;
    managedRoom.lastUpdate = room.lastUpdate;
}

+ (NSString *)primaryKey {
    return @"internalId";
}

- (BOOL)isPublic
{
    return self.type == kNCRoomTypePublic;
}

- (BOOL)canModerate
{
    return (self.participantType == kNCParticipantTypeOwner || self.participantType == kNCParticipantTypeModerator) && ![self isLockedOneToOne];
}

- (BOOL)isNameEditable
{
    return [self canModerate] && self.type != kNCRoomTypeOneToOne;
}

- (BOOL)isLockedOneToOne
{
    return self.type == kNCRoomTypeOneToOne && [[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityLockedOneToOneRooms];
}

- (BOOL)isMyNotes
{
    return self.type == kNCRoomTypeNotes;
}

- (BOOL)userCanStartCall
{
    if ([[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityStartCallFlag] && !self.canStartCall) {
        return NO;
    }
    return YES;
}

- (BOOL)isLeavable
{
    // Allow users to leave when there are no moderators in the room
    // (No need to check room type because in one2one rooms users will always be moderators)
    // or when in a group call and there are other participants.
    return ![self canModerate] || (self.type != kNCRoomTypeOneToOne && [self.participants count] > 1);
}

- (NSString *)deletionMessage
{
    NSString *message = @"Do you really want to delete this conversation?";
    if (self.type == kNCRoomTypeOneToOne) {
        message = [NSString stringWithFormat:@"If you delete the conversation, it will also be deleted for %@", self.displayName];
    } else if (self.type == kNCRoomTypeNotes) {
        message = @"Do you really want to delete \"My notes\"?";
    } else if ([self.participants count] > 1) {
        message = @"If you delete the conversation, it will also be deleted for all other participants.";
    }
    
    return message;
}

- (NSString *)notificationLevelString
{
    return [self stringForNotificationLevel:self.notificationLevel];
}

- (NSString *)stringForNotificationLevel:(NCRoomNotificationLevel)level
{
    NSString *levelString = @"Default";
    switch (level) {
        case kNCRoomNotificationLevelAlways:
            levelString = @"All messages";
            break;
        case kNCRoomNotificationLevelMention:
            levelString = @"@-mentions only";
            break;
        case kNCRoomNotificationLevelNever:
            levelString = @"Off";
            break;
        default:
            break;
    }
    return levelString;
}

- (NSString *)lastMessageString
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    BOOL ownMessage = [self.lastMessage.actorId isEqualToString:activeAccount.userId];
    NSString *actorName = [[self.lastMessage.actorDisplayName componentsSeparatedByString:@" "] objectAtIndex:0];
    // For own messages
    if (ownMessage) {
        actorName = @"You";
    }
    // For guests
    if ([self.lastMessage.actorDisplayName isEqualToString:@""]) {
        actorName = @"Guest";
    }
    // No actor name cases
    if (self.lastMessage.isSystemMessage || (self.type == kNCRoomTypeOneToOne && !ownMessage) || self.type == kNCRoomTypeChangelog || self.type == kNCRoomTypeNotes) {
        actorName = @"";
    }
    // Use only the first name
    if (![actorName isEqualToString:@""]) {
        actorName = [NSString stringWithFormat:@"%@: ", [[actorName componentsSeparatedByString:@" "] objectAtIndex:0]];
    }
    // Add the last message
    NSString *lastMessage = [NSString stringWithFormat:@"%@%@", actorName, self.lastMessage.parsedMessage.string];
    
    return lastMessage;
}

- (NCChatMessage *)lastMessage
{
    if (self.lastMessageId) {
        NCChatMessage *unmanagedChatMessage = nil;
        NCChatMessage *managedChatMessage = [NCChatMessage objectsWhere:@"internalId = %@", self.lastMessageId].firstObject;
        if (managedChatMessage) {
            unmanagedChatMessage = [[NCChatMessage alloc] initWithValue:managedChatMessage];
        }
        return unmanagedChatMessage;
    }
    
    return nil;
}


@end
