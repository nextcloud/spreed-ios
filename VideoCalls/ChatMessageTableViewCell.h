//
//  ChatMessageTableViewCell.h
//  VideoCalls
//
//  Created by Ivan Sein on 24.04.18.
//  Copyright © 2018 struktur AG. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "ChatTableViewCell.h"
#import "MessageBodyTextView.h"

static CGFloat kChatMessageCellMinimumHeight    = 50.0;
static CGFloat kChatMessageCellAvatarHeight     = 30.0;

static NSString *ChatMessageCellIdentifier      = @"ChatMessageCellIdentifier";
static NSString *ReplyMessageCellIdentifier     = @"ReplyMessageCellIdentifier";
static NSString *AutoCompletionCellIdentifier   = @"AutoCompletionCellIdentifier";

@class QuotedMessageView;

@interface ChatMessageTableViewCell : ChatTableViewCell

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) QuotedMessageView *quotedMessageView;
@property (nonatomic, strong) MessageBodyTextView *bodyTextView;
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UIView *statusView;
@property (nonatomic, strong) UIImageView *userStatusImageView;

+ (CGFloat)defaultFontSize;
- (void)setGuestAvatar:(NSString *)displayName;
- (void)setBotAvatar;
- (void)setChangelogAvatar;
- (void)setNotesAvatar;
- (void)setDeliveryState:(ChatMessageDeliveryState)state;
- (void)setUserStatus:(NSString *)userStatus;

@end
