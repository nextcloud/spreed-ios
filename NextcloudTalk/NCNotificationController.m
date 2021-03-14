/**
 * @copyright Copyright (c) 2020 Ivan Sein <ivan@nextcloud.com>
 *
 * @author Ivan Sein <ivan@nextcloud.com>
 *
 * @license GNU GPL version 3 or any later version
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "NCNotificationController.h"
#import <UserNotifications/UserNotifications.h>

#import "NCAPIController.h"
#import "NCConnectionController.h"
#import "NCNotification.h"
#import "NCRoomsManager.h"
#import "NCSettingsController.h"
#import "NCUserInterfaceController.h"
#import "CallKitManager.h"
#import "NCIntentController.h"

NSString * const NCNotificationControllerWillPresentNotification    = @"NCNotificationControllerWillPresentNotification";
NSString * const NCLocalNotificationJoinChatNotification            = @"NCLocalNotificationJoinChatNotification";

@interface NCNotificationController () <UNUserNotificationCenterDelegate>

@property (nonatomic, strong) UNUserNotificationCenter *notificationCenter;
@property (nonatomic, strong) NSMutableDictionary *serverNotificationsAttempts; // notificationId -> get attempts

@end

@implementation NCNotificationController

+ (NCNotificationController *)sharedInstance
{
    static dispatch_once_t once;
    static NCNotificationController *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
        _notificationCenter.delegate = self;
        _serverNotificationsAttempts = [[NSMutableDictionary alloc] init];
    }
    
    return self;
}

- (void)requestAuthorization
{
    UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
    [_notificationCenter requestAuthorizationWithOptions:authOptions completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (granted) {
            NSLog(@"User notifications permission granted.");
        } else {
            NSLog(@"User notifications permission denied.");
        }
    }];
}

- (void)processBackgroundPushNotification:(NCPushNotification *)pushNotification
{
    if (pushNotification) {
        NSInteger notificationId = pushNotification.notificationId;
        if (pushNotification.type == NCPushNotificationTypeDelete) {
            [self removeNotificationWithNotificationId:notificationId forAccountId:pushNotification.accountId];
        } else if (pushNotification.type == NCPushNotificationTypeDeleteAll) {
            [self removeAllNotificationsForAccountId:pushNotification.accountId];
        } else {
            NSLog(@"Push Notification of an unknown type received");
        }
    }
}

- (void)showLocalNotification:(NCLocalNotificationType)type withUserInfo:(NSDictionary *)userInfo
{
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    
    switch (type) {
        case kNCLocalNotificationTypeMissedCall:
            {
                NSString *missedCallString = NSLocalizedString(@"Missed call from", nil);
                content.body = [NSString stringWithFormat:@"☎️ %@ %@", missedCallString, [userInfo objectForKey:@"displayName"]];
                content.userInfo = userInfo;
            }
            break;
            
        case kNCLocalNotificationTypeCancelledCall:
        {
            NSString *cancelledCallString = NSLocalizedString(@"Cancelled call from another account", nil);
            content.body = [NSString stringWithFormat:@"☎️ %@", cancelledCallString];
            content.userInfo = userInfo;
        }
            break;
            
        case kNCLocalNotificationTypeFailedSendChat:
        {
            NSString *failedSendChatString = NSLocalizedString(@"Failed to send message", nil);
            content.body = [NSString stringWithFormat:@"%@", failedSendChatString];
            content.userInfo = userInfo;
        }
            break;
            
        default:
            break;
    }
    
    NSString *identifier = [NSString stringWithFormat:@"Notification-%f", [[NSDate date] timeIntervalSince1970]];
    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
    [_notificationCenter addNotificationRequest:request withCompletionHandler:nil];
    
    NSString *accountId = [userInfo objectForKey:@"accountId"];
    [[NCDatabaseManager sharedInstance] increaseUnreadBadgeNumberForAccountId:accountId];
    [self updateAppIconBadgeNumber];
}

- (void)showLocalNotificationForIncomingCallWithPushNotificaion:(NCPushNotification *)pushNotification
{
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.body = pushNotification.bodyForRemoteAlerts;
    content.threadIdentifier = pushNotification.roomToken;
    content.sound = [UNNotificationSound defaultSound];
    NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] init];
    [userInfo setObject:pushNotification.jsonString forKey:@"pushNotification"];
    [userInfo setObject:pushNotification.accountId forKey:@"accountId"];
    content.userInfo = userInfo;
    
    NSString *identifier = [NSString stringWithFormat:@"Notification-%f", [[NSDate date] timeIntervalSince1970]];
    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
    [_notificationCenter addNotificationRequest:request withCompletionHandler:nil];
    
    [[NCDatabaseManager sharedInstance] increaseUnreadBadgeNumberForAccountId:pushNotification.accountId];
    [self updateAppIconBadgeNumber];
}

- (void)showIncomingCallForPushNotification:(NCPushNotification *)pushNotification
{
    if ([CallKitManager isCallKitAvailable]) {
        [[CallKitManager sharedInstance] reportIncomingCall:pushNotification.roomToken withDisplayName:@"Incoming call" forAccountId:pushNotification.accountId];
    } else {
        [[CallKitManager sharedInstance] reportIncomingCallForNonCallKitDevicesWithPushNotification:pushNotification];
    }
}

- (void)updateAppIconBadgeNumber
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].applicationIconBadgeNumber = [[NCDatabaseManager sharedInstance] numberOfUnreadNotifications];
    });
}

- (void)removeAllNotificationsForAccountId:(NSString *)accountId
{
    // Check in pending notifications
    [_notificationCenter getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> * _Nonnull requests) {
        for (UNNotificationRequest *notificationRequest in requests) {
            NSString *notificationAccountId = [notificationRequest.content.userInfo objectForKey:@"accountId"];
            if (notificationAccountId && [notificationAccountId isEqualToString:accountId]) {
                [self->_notificationCenter removeDeliveredNotificationsWithIdentifiers:@[notificationRequest.identifier]];
            }
        }
    }];
    // Check in delivered notifications
    [_notificationCenter getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {
        for (UNNotification *notification in notifications) {
            NSString *notificationAccountId = [notification.request.content.userInfo objectForKey:@"accountId"];
            if (notificationAccountId && [notificationAccountId isEqualToString:accountId]) {
                [self->_notificationCenter removeDeliveredNotificationsWithIdentifiers:@[notification.request.identifier]];
            }
        }
    }];
    
    [[NCDatabaseManager sharedInstance] resetUnreadBadgeNumberForAccountId:accountId];
    [self updateAppIconBadgeNumber];
}

- (void)removeNotificationWithNotificationId:(NSInteger)notificationId forAccountId:(NSString *)accountId
{
    // Check in pending notifications
    [_notificationCenter getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> * _Nonnull requests) {
        for (UNNotificationRequest *notificationRequest in requests) {
            NSString *notificationString = [notificationRequest.content.userInfo objectForKey:@"pushNotification"];
            NSString *notificationAccountId = [notificationRequest.content.userInfo objectForKey:@"accountId"];
            NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:notificationString withAccountId:notificationAccountId];
            if (pushNotification && [pushNotification.accountId isEqualToString:accountId] && pushNotification.notificationId == notificationId) {
                [self->_notificationCenter removeDeliveredNotificationsWithIdentifiers:@[notificationRequest.identifier]];
                [[NCDatabaseManager sharedInstance] decreaseUnreadBadgeNumberForAccountId:accountId];
            }
        }
    }];
    // Check in delivered notifications
    [_notificationCenter getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {
        for (UNNotification *notification in notifications) {
            NSString *notificationString = [notification.request.content.userInfo objectForKey:@"pushNotification"];
            NSString *notificationAccountId = [notification.request.content.userInfo objectForKey:@"accountId"];
            NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:notificationString withAccountId:notificationAccountId];
            if (pushNotification && [pushNotification.accountId isEqualToString:accountId] && pushNotification.notificationId == notificationId) {
                [self->_notificationCenter removeDeliveredNotificationsWithIdentifiers:@[notification.request.identifier]];
                [[NCDatabaseManager sharedInstance] decreaseUnreadBadgeNumberForAccountId:accountId];
            }
        }
    }];
    
    [self updateAppIconBadgeNumber];
}

#pragma mark - UNUserNotificationCenter delegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    // Called when a notification is delivered to a foreground app.
    [[NSNotificationCenter defaultCenter] postNotificationName:NCNotificationControllerWillPresentNotification object:self userInfo:nil];
    completionHandler(UNNotificationPresentationOptionAlert);
    
    // Remove the notification from Notification Center if it is from the active account
    NSString *notificationAccountId = [notification.request.content.userInfo objectForKey:@"accountId"];
    if (notificationAccountId && [[[NCDatabaseManager sharedInstance] activeAccount].accountId isEqualToString:notificationAccountId]) {
        [self removeAllNotificationsForAccountId:notificationAccountId];
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completionHandler
{
    if ([NCRoomsManager sharedInstance].callViewController) {
        completionHandler();
        return;
    }
    
    UNNotificationRequest *notificationRequest = response.notification.request;
    NCLocalNotificationType localNotificationType = (NCLocalNotificationType)[[notificationRequest.content.userInfo objectForKey:@"localNotificationType"] integerValue];
    NSString *notificationString = [notificationRequest.content.userInfo objectForKey:@"pushNotification"];
    NSString *notificationAccountId = [notificationRequest.content.userInfo objectForKey:@"accountId"];
    NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:notificationString withAccountId:notificationAccountId];
    
    // Change account if notification is from another account
    if (notificationAccountId && ![[[NCDatabaseManager sharedInstance] activeAccount].accountId isEqualToString:notificationAccountId]) {
        // Leave chat before changing accounts
        if ([[NCRoomsManager sharedInstance] chatViewController]) {
            [[[NCRoomsManager sharedInstance] chatViewController] leaveChat];
        }
        // Set notification account active
        [[NCSettingsController sharedInstance] setActiveAccountWithAccountId:notificationAccountId];
    }
    
    // Handle notification response
    if (pushNotification) {
        if ([response isKindOfClass:[UNTextInputNotificationResponse class]]) {
            UNTextInputNotificationResponse *textInputResponse = (UNTextInputNotificationResponse *)response;
            pushNotification.responseUserText = textInputResponse.userText;
            
            [self handlePushNotificationResponseWithUserText:pushNotification withCompletionHandler:completionHandler];
        } else {
            [self handlePushNotificationResponse:pushNotification withCompletionHandler:completionHandler];
        }
    } else if (localNotificationType > 0) {
        [self handleLocalNotificationResponse:notificationRequest.content.userInfo withCompletionHandler:completionHandler];
    }
}

- (void)handlePushNotificationResponseWithUserText:(NCPushNotification *)pushNotification withCompletionHandler:(void (^)(void))completionHandler
{
    NSLog(@"Recevied push-notification with user input -> sending chat message");
    
    TalkAccount *pushAccount = [[NCDatabaseManager sharedInstance] talkAccountForAccountId:pushNotification.accountId];
    
    UIApplication *application = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier sendTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:sendTask];
        sendTask = UIBackgroundTaskInvalid;
    }];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[NCAPIController sharedInstance] sendChatMessage:pushNotification.responseUserText toRoom:pushNotification.roomToken displayName:nil replyTo:-1 referenceId:nil forAccount:pushAccount withCompletionBlock:^(NSError *error) {

            if (error) {
                NSLog(@"Could not send chat message. Error: %@", error.description);
                
                // Display local push-notification to inform user
                NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:pushNotification.roomToken forKey:@"roomToken"];
                [userInfo setValue:@(kNCLocalNotificationTypeFailedSendChat) forKey:@"localNotificationType"];
                [userInfo setObject:pushNotification.accountId forKey:@"accountId"];
                [userInfo setObject:pushNotification.responseUserText forKey:@"responseUserText"];
                
                [[NCNotificationController sharedInstance] showLocalNotification:kNCLocalNotificationTypeFailedSendChat withUserInfo:userInfo];
            } else {
                // We replied to the message, so we can assume, we read it as well
                [[NCDatabaseManager sharedInstance] decreaseUnreadBadgeNumberForAccountId:pushNotification.accountId];
                [self updateAppIconBadgeNumber];
                [[NCIntentController sharedInstance] donateSendMessageIntentForRoomToken:pushNotification.roomToken withAccountId:pushNotification.accountId];
            }
            
            [application endBackgroundTask:sendTask];
            sendTask = UIBackgroundTaskInvalid;
        }];


    });
    
    completionHandler();
}

- (void)handlePushNotificationResponse:(NCPushNotification *)pushNotification withCompletionHandler:(void (^)(void))completionHandler
{
    if (pushNotification) {
        switch (pushNotification.type) {
            case NCPushNotificationTypeCall:
            {
                [[NCUserInterfaceController sharedInstance] presentAlertForPushNotification:pushNotification];
            }
                break;
            case NCPushNotificationTypeRoom:
            case NCPushNotificationTypeChat:
            {
                [[NCUserInterfaceController sharedInstance] presentChatForPushNotification:pushNotification];
            }
                break;
            default:
                break;
        }
    }
    
    completionHandler();
}

- (void)handleLocalNotificationResponse:(NSDictionary *)notificationUserInfo withCompletionHandler:(void (^)(void))completionHandler
{
    NCLocalNotificationType localNotificationType = (NCLocalNotificationType)[[notificationUserInfo objectForKey:@"localNotificationType"] integerValue];
    if (localNotificationType > 0) {
        switch (localNotificationType) {
            case kNCLocalNotificationTypeMissedCall:
            case kNCLocalNotificationTypeCancelledCall:
            case kNCLocalNotificationTypeFailedSendChat:
            {
                [[NCUserInterfaceController sharedInstance] presentChatForLocalNotification:notificationUserInfo];
            }
                break;
            default:
                break;
        }
    }
    
    completionHandler();
}

@end
