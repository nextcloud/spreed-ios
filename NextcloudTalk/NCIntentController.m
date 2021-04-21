/**
 * @copyright Copyright (c) 2021 Marcel Müller <marcel-mueller@gmx.de>
 *
 * @author Marcel Müller <marcel-mueller@gmx.de>
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

#import <Intents/INInteraction.h>
#import <Intents/INSendMessageIntent.h>
#import <Intents/INSendMessageIntent_Deprecated.h>
#import <Intents/INSpeakableString.h>
#import <Intents/INOutgoingMessageType.h>
#import <Intents/INImage.h>
#import <IntentsUI/INImage+IntentsUI.h>

#import "NCIntentController.h"
#import "NCRoomsManager.h"
#import "NCAPIController.h"
#import "NCDatabaseManager.h"

@implementation NCIntentController

+ (NCIntentController *)sharedInstance
{
    static dispatch_once_t once;
    static NCIntentController *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)donateSendMessageIntentForRoom:(NCRoom *)room
{
    // Go with iOS 13 here, as we can't access the intent property in a shareExtension with earlier version
    // See: https://developer.apple.com/documentation/foundation/nsextensioncontext/3180173-intent?language=objc
    if (@available(iOS 13.0, *)) {
        INSpeakableString *groupName = [[INSpeakableString alloc] initWithSpokenPhrase:room.displayName];
        INSendMessageIntent *sendMessageIntent;
        
        if (@available(iOS 14.0, *)) {
            sendMessageIntent = [[INSendMessageIntent alloc] initWithRecipients:nil
                                                            outgoingMessageType:INOutgoingMessageTypeOutgoingMessageText
                                                                        content:nil
                                                             speakableGroupName:groupName
                                                         conversationIdentifier:room.internalId
                                                                    serviceName:nil
                                                                         sender:nil
                                                                    attachments:nil];
        } else {
            sendMessageIntent = [[INSendMessageIntent alloc] initWithRecipients:nil
                                                                        content:nil
                                                             speakableGroupName:groupName
                                                         conversationIdentifier:room.internalId
                                                                    serviceName:nil
                                                                         sender:nil];
        }

        switch (room.type) {
            case kNCRoomTypeOneToOne:
            {
                TalkAccount *account = [[NCDatabaseManager sharedInstance] talkAccountForAccountId:room.accountId];
                [[NCAPIController sharedInstance] getUserAvatarForUser:room.name andSize:128 usingAccount:account withCompletionBlock:^(UIImage *image, NSError *error) {
                    if (image) {
                        [sendMessageIntent setImage:[INImage imageWithUIImage:image] forParameterNamed:@"speakableGroupName"];
                        [self donateMessageSentIntent:sendMessageIntent];
                    }
                }];
                break;
            }
            case kNCRoomTypeGroup:
            {
                UIImage *avatarImage = [self getAvatarWithImage:[UIImage imageNamed:@"group"] withSize:CGSizeMake(128, 128)];
                [sendMessageIntent setImage:[INImage imageWithUIImage:avatarImage] forParameterNamed:@"speakableGroupName"];
                [self donateMessageSentIntent:sendMessageIntent];
                break;
            }

            case kNCRoomTypePublic:
            {
                UIImage *avatarImage = [self getAvatarWithImage:[UIImage imageNamed:@"public"] withSize:CGSizeMake(128, 128)];
                [sendMessageIntent setImage:[INImage imageWithUIImage:avatarImage] forParameterNamed:@"speakableGroupName"];
                [self donateMessageSentIntent:sendMessageIntent];
                break;
            }
   
            default:
                break;
        }
    }
}

- (void)donateSendMessageIntentForRoomToken:(NSString *)token withAccountId:(NSString *)accountId
{
    NCRoom *room = [[NCRoomsManager sharedInstance] roomWithToken:token forAccountId:accountId];
    
    if (room) {
        [self donateSendMessageIntentForRoom:room];
    }
}

- (void)donateMessageSentIntent:(INSendMessageIntent *)sendMessageIntent
{
    INInteraction *interaction = [[INInteraction alloc] initWithIntent:sendMessageIntent response:nil];
    [interaction donateInteractionWithCompletion:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"Failed to donate sendMessageIntent: %@", [error description]);
        } else {
            NSLog(@"SendMessageIntent successfully donated");
        }
    }];
}

- (UIImage *)getAvatarWithImage:(UIImage *)image withSize:(CGSize)size
{
    if (image) {
        UIGraphicsBeginImageContext(size);
        
        // #d5d5d5 - we can't donate 2 images for dark/light mode, so just be consistent here
        [[UIColor colorWithRed: 0.84 green: 0.84 blue: 0.84 alpha: 1.00] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        
        CGFloat imageScale = image.scale;
        CGFloat imageWidth = (image.size.width * imageScale);
        CGFloat imageHeight = (image.size.height * imageScale);
        
        CGFloat positionX = size.width / 2 - imageWidth / 2;
        CGFloat positionY = size.height / 2 - imageHeight / 2;
        [image drawInRect:CGRectMake(positionX, positionY, imageWidth, imageHeight)];
        
        UIImage *avatarImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
     
        return avatarImage;
    }
    
    return nil;
}



@end
