//
//  RoomInfoTableViewController.m
//  VideoCalls
//
//  Created by Ivan Sein on 02.07.18.
//  Copyright © 2018 struktur AG. All rights reserved.
//

#import "RoomInfoTableViewController.h"


#import "AddParticipantsTableViewController.h"
#import "ContactsTableViewCell.h"
#import "RoomNameTableViewCell.h"
#import "HeaderWithButton.h"
#import "NCAPIController.h"
#import "NCDatabaseManager.h"
#import "NCRoomsManager.h"
#import "NCRoomParticipant.h"
#import "NCSettingsController.h"
#import "NCUserInterfaceController.h"
#import "NCUtils.h"
#import "UIImageView+Letters.h"
#import "UIImageView+AFNetworking.h"

typedef enum RoomInfoSection {
    kRoomInfoSectionName = 0,
    kRoomInfoSectionActions,
    kRoomInfoSectionPublic,
    kRoomInfoSectionWebinar,
    kRoomInfoSectionParticipants,
    kRoomInfoSectionDestructive
} RoomInfoSection;

typedef enum RoomAction {
    kRoomActionFavorite = 0,
    kRoomActionNotifications,
    kRoomActionSendLink
} RoomAction;

typedef enum PublicAction {
    kPublicActionPublicToggle = 0,
    kPublicActionPassword
} PublicAction;

typedef enum WebinarAction {
    kWebinarActionLobby = 0,
    kWebinarActionLobbyTimer
} WebinarAction;

typedef enum DestructiveAction {
    kDestructiveActionLeave = 0,
    kDestructiveActionDelete
} DestructiveAction;

typedef enum ModificationError {
    kModificationErrorRename = 0,
    kModificationErrorFavorite,
    kModificationErrorNotifications,
    kModificationErrorShare,
    kModificationErrorPassword,
    kModificationErrorLobby,
    kModificationErrorModeration,
    kModificationErrorRemove,
    kModificationErrorLeave,
    kModificationErrorLeaveModeration,
    kModificationErrorDelete
} ModificationError;

#define k_set_password_textfield_tag    98

@interface RoomInfoTableViewController () <UITextFieldDelegate, UIGestureRecognizerDelegate, AddParticipantsTableViewControllerDelegate>

@property (nonatomic, strong) NCRoom *room;
@property (nonatomic, strong) NCChatViewController *chatViewController;
@property (nonatomic, strong) NSString *roomName;
@property (nonatomic, strong) NSMutableArray *roomParticipants;
@property (nonatomic, strong) UITextField *roomNameTextField;
@property (nonatomic, strong) UISwitch *publicSwtich;
@property (nonatomic, strong) UISwitch *lobbySwtich;
@property (nonatomic, strong) UIDatePicker *lobbyDatePicker;
@property (nonatomic, strong) UITextField *lobbyDateTextField;
@property (nonatomic, strong) UIActivityIndicatorView *modifyingRoomView;
@property (nonatomic, strong) HeaderWithButton *headerView;
@property (nonatomic, strong) UIAlertAction *setPasswordAction;

@end

@implementation RoomInfoTableViewController

- (instancetype)initForRoom:(NCRoom *)room
{
    return [self initForRoom:room fromChatViewController:nil];
}

- (instancetype)initForRoom:(NCRoom *)room fromChatViewController:(NCChatViewController *)chatViewController
{
    self = [super init];
    if (self) {
        _room = room;
        _chatViewController = chatViewController;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.navigationItem.title = @"Conversation info";
    [self.navigationController.navigationBar setTitleTextAttributes:
     @{NSForegroundColorAttributeName:[UIColor whiteColor]}];
    self.navigationController.navigationBar.tintColor = [UIColor whiteColor];
    self.navigationController.navigationBar.translucent = NO;
    self.navigationController.navigationBar.barTintColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
    
    if (@available(iOS 13.0, *)) {
        UIColor *themeColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = themeColor;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[UIColor whiteColor]};
        self.navigationItem.standardAppearance = appearance;
        self.navigationItem.compactAppearance = appearance;
        self.navigationItem.scrollEdgeAppearance = appearance;
    }
    
    _roomParticipants = [[NSMutableArray alloc] init];
    
    _publicSwtich = [[UISwitch alloc] initWithFrame:CGRectZero];
    [_publicSwtich addTarget: self action: @selector(publicValueChanged:) forControlEvents:UIControlEventValueChanged];
    
    _lobbySwtich = [[UISwitch alloc] initWithFrame:CGRectZero];
    [_lobbySwtich addTarget: self action: @selector(lobbyValueChanged:) forControlEvents:UIControlEventValueChanged];
    
    _lobbyDatePicker = [[UIDatePicker alloc] init];
    _lobbyDatePicker.datePickerMode = UIDatePickerModeDateAndTime;
    _lobbyDateTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, 00, 200, 30)];
    _lobbyDateTextField.textAlignment = NSTextAlignmentRight;
    _lobbyDateTextField.placeholder = @"Manual";
    _lobbyDateTextField.adjustsFontSizeToFitWidth = YES;
    [_lobbyDateTextField setInputView:_lobbyDatePicker];
    [self setupLobbyDatePicker];
    
    _modifyingRoomView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    
    _headerView = [[HeaderWithButton alloc] init];
    [_headerView.button setTitle:@"Add" forState:UIControlStateNormal];
    [_headerView.button addTarget:self action:@selector(addParticipantsButtonPressed) forControlEvents:UIControlEventTouchUpInside];
    
    [self.tableView registerNib:[UINib nibWithNibName:kContactsTableCellNibName bundle:nil] forCellReuseIdentifier:kContactCellIdentifier];
    [self.tableView registerNib:[UINib nibWithNibName:kRoomNameTableCellNibName bundle:nil] forCellReuseIdentifier:kRoomNameCellIdentifier];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];
    
    if (!_chatViewController) {
        UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                      target:self action:@selector(cancelButtonPressed)];
        self.navigationController.navigationBar.topItem.leftBarButtonItem = cancelButton;
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didUpdateRoom:) name:NCRoomsManagerDidUpdateRoomNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [[NCRoomsManager sharedInstance] updateRoom:_room.token];
    [self getRoomParticipants];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)dismissKeyboard
{
    [_roomNameTextField resignFirstResponder];
}

- (void)cancelButtonPressed
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Utils

- (void)getRoomParticipants
{
    [[NCAPIController sharedInstance] getParticipantsFromRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSMutableArray *participants, NSError *error) {
        _roomParticipants = participants;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange([self getSectionForRoomInfoSection:kRoomInfoSectionParticipants], 1)] withRowAnimation:UITableViewRowAnimationNone];
        [self removeModifyingRoomUI];
    }];
}

- (NSArray *)getRoomInfoSections
{
    NSMutableArray *sections = [[NSMutableArray alloc] init];
    // Room name section
    [sections addObject:[NSNumber numberWithInt:kRoomInfoSectionName]];
    // Room actions section
    [sections addObject:[NSNumber numberWithInt:kRoomInfoSectionActions]];
    // Moderator sections
    if (_room.canModerate && !_room.isMyNotes) {
        // Public room section
        [sections addObject:[NSNumber numberWithInt:kRoomInfoSectionPublic]];
        // Webinar section
        if (_room.type != kNCRoomTypeOneToOne && [[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityWebinaryLobby]) {
            [sections addObject:[NSNumber numberWithInt:kRoomInfoSectionWebinar]];
        }
    }
    // Participants section
    [sections addObject:[NSNumber numberWithInt:kRoomInfoSectionParticipants]];
    // Destructive actions section
    [sections addObject:[NSNumber numberWithInt:kRoomInfoSectionDestructive]];
    return [NSArray arrayWithArray:sections];
}

- (NSInteger)getSectionForRoomInfoSection:(RoomInfoSection)section
{
    NSInteger sectionNumber = [[self getRoomInfoSections] indexOfObject:[NSNumber numberWithInt:section]];
    if(NSNotFound != sectionNumber) {
        return sectionNumber;
    }
    return 0;
}

- (NSArray *)getRoomActions
{
    NSMutableArray *actions = [[NSMutableArray alloc] init];
    // Favorite action
    [actions addObject:[NSNumber numberWithInt:kRoomActionFavorite]];
    // Notification levels action
    if ([[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityNotificationLevels] && !_room.isMyNotes) {
        [actions addObject:[NSNumber numberWithInt:kRoomActionNotifications]];
    }
    // Public room actions
    if (_room.isPublic) {
        [actions addObject:[NSNumber numberWithInt:kRoomActionSendLink]];
    }
    return [NSArray arrayWithArray:actions];
}

- (NSIndexPath *)getIndexPathForRoomAction:(RoomAction)action
{
    NSIndexPath *actionIndexPath = [NSIndexPath indexPathForRow:0 inSection:kRoomInfoSectionActions];
    NSInteger actionRow = [[self getRoomActions] indexOfObject:[NSNumber numberWithInt:action]];
    if(NSNotFound != actionRow) {
        actionIndexPath = [NSIndexPath indexPathForRow:actionRow inSection:kRoomInfoSectionActions];
    }
    return actionIndexPath;
}

- (NSArray *)getPublicActions
{
    NSMutableArray *actions = [[NSMutableArray alloc] init];
    // Public room toggle
    [actions addObject:[NSNumber numberWithInt:kPublicActionPublicToggle]];
    // Password protection
    if (_room.isPublic) {
        [actions addObject:[NSNumber numberWithInt:kPublicActionPassword]];
    }
    return [NSArray arrayWithArray:actions];
}

- (NSArray *)getWebinarActions
{
    NSMutableArray *actions = [[NSMutableArray alloc] init];
    // Lobby toggle
    [actions addObject:[NSNumber numberWithInt:kWebinarActionLobby]];
    // Lobby timer
    if (_room.lobbyState == NCRoomLobbyStateModeratorsOnly) {
        [actions addObject:[NSNumber numberWithInt:kWebinarActionLobbyTimer]];
    }
    return [NSArray arrayWithArray:actions];
}

- (NSArray *)getRoomDestructiveActions
{
    NSMutableArray *actions = [[NSMutableArray alloc] init];
    // Leave room
    if (_room.isLeavable) {
        [actions addObject:[NSNumber numberWithInt:kDestructiveActionLeave]];
    }
    // Delete room
    if (_room.canModerate) {
        [actions addObject:[NSNumber numberWithInt:kDestructiveActionDelete]];
    }
    return [NSArray arrayWithArray:actions];
}

- (BOOL)isAppUser:(NCRoomParticipant *)participant
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    if ([participant.userId isEqualToString:activeAccount.userId]) {
        return YES;
    }
    return NO;
}

- (void)setModifyingRoomUI
{
    [_modifyingRoomView startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_modifyingRoomView];
    self.tableView.userInteractionEnabled = NO;
}

- (void)removeModifyingRoomUI
{
    [_modifyingRoomView stopAnimating];
    self.navigationItem.rightBarButtonItem = nil;
    self.tableView.userInteractionEnabled = YES;
}

- (void)showRoomModificationError:(ModificationError)error
{
    [self removeModifyingRoomUI];
    NSString *errorDescription = @"";
    switch (error) {
        case kModificationErrorRename:
            errorDescription = @"Could not rename the conversation";
            break;
            
        case kModificationErrorFavorite:
            errorDescription = @"Could not change favorite setting";
            break;
            
        case kModificationErrorNotifications:
            errorDescription = @"Could not change notifications setting";
            break;
            
        case kModificationErrorShare:
            errorDescription = @"Could not change sharing permissions of the conversation";
            break;
            
        case kModificationErrorPassword:
            errorDescription = @"Could not change password protection settings";
            break;
            
        case kModificationErrorLobby:
            errorDescription = @"Could not change lobby state of the conversation";
            break;
            
        case kModificationErrorModeration:
            errorDescription = @"Could not change moderation permissions of the participant";
            break;
            
        case kModificationErrorRemove:
            errorDescription = @"Could not remove participant";
            break;
        
        case kModificationErrorLeave:
            errorDescription = @"Could not leave conversation";
            break;
            
        case kModificationErrorLeaveModeration:
            errorDescription = @"You need to promote a new moderator before you can leave this conversation";
            break;
            
        case kModificationErrorDelete:
            errorDescription = @"Could not delete conversation";
            break;
            
        default:
            break;
    }
    
    UIAlertController *renameDialog =
    [UIAlertController alertControllerWithTitle:errorDescription
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [renameDialog addAction:okAction];
    [self presentViewController:renameDialog animated:YES completion:nil];
}

- (void)showConfirmationDialogForDestructiveAction:(DestructiveAction)action
{
    NSString *title = @"";
    NSString *message = @"";
    UIAlertAction *confirmAction = nil;
    
    switch (action) {
        case kDestructiveActionLeave:
        {
            title = @"Leave conversation";
            message = @"Do you really want to leave this conversation?";
            confirmAction = [UIAlertAction actionWithTitle:@"Leave" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                [self leaveRoom];
            }];
        }
            break;
        case kDestructiveActionDelete:
        {
            title = @"Delete conversation";
            message = _room.deletionMessage;
            confirmAction = [UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                [self deleteRoom];
            }];
        }
            break;
    }
    
    UIAlertController *confirmDialog =
    [UIAlertController alertControllerWithTitle:title
                                        message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
    [confirmDialog addAction:confirmAction];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [confirmDialog addAction:cancelAction];
    [self presentViewController:confirmDialog animated:YES completion:nil];
}

- (void)presentNotificationLevelSelector
{
    UIAlertController *optionsActionSheet =
    [UIAlertController alertControllerWithTitle:@"Notifications"
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
    [optionsActionSheet addAction:[self actionForNotificationLevel:kNCRoomNotificationLevelAlways]];
    [optionsActionSheet addAction:[self actionForNotificationLevel:kNCRoomNotificationLevelMention]];
    [optionsActionSheet addAction:[self actionForNotificationLevel:kNCRoomNotificationLevelNever]];
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    optionsActionSheet.popoverPresentationController.sourceView = self.tableView;
    optionsActionSheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:[self getIndexPathForRoomAction:kRoomActionNotifications]];
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

- (UIAlertAction *)actionForNotificationLevel:(NCRoomNotificationLevel)level
{
    UIAlertAction *action = [UIAlertAction actionWithTitle:[_room stringForNotificationLevel:level]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^void (UIAlertAction *action) {
                                                       [self setNotificationLevel:level];
                                                   }];
    if (_room.notificationLevel == level) {
        [action setValue:[[UIImage imageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
    }
    return action;
}

#pragma mark - Room Manager notifications

- (void)didUpdateRoom:(NSNotification *)notification
{
    [self removeModifyingRoomUI];
    
    NCRoom *room = [notification.userInfo objectForKey:@"room"];
    if (!room || ![room.token isEqualToString:_room.token]) {
        return;
    }
    
    _room = room;
    [self setupLobbyDatePicker];
    [self.tableView reloadData];
}

#pragma mark - Room options

- (void)renameRoom
{
    NSString *newRoomName = [_roomNameTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([newRoomName isEqualToString:_room.name]) {
        return;
    }
    if ([newRoomName isEqualToString:@""]) {
        _roomNameTextField.text = _room.name;
        return;
    }
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] renameRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withName:newRoomName andCompletionBlock:^(NSError *error) {
        if (!error) {
            [[NCRoomsManager sharedInstance] updateRoom:_room.token];
        } else {
            NSLog(@"Error renaming the room: %@", error.description);
            [self.tableView reloadData];
            [self showRoomModificationError:kModificationErrorRename];
        }
    }];
}

- (void)addRoomToFavorites
{
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] addRoomToFavorites:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            [[NCRoomsManager sharedInstance] updateRoom:_room.token];
        } else {
            NSLog(@"Error adding the room to favorites: %@", error.description);
            [self.tableView reloadData];
            [self showRoomModificationError:kModificationErrorFavorite];
        }
    }];
}

- (void)removeRoomFromFavorites
{
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] removeRoomFromFavorites:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            [[NCRoomsManager sharedInstance] updateRoom:_room.token];
        } else {
            NSLog(@"Error removing the room from favorites: %@", error.description);
            [self.tableView reloadData];
            [self showRoomModificationError:kModificationErrorFavorite];
        }
    }];
}

- (void)setNotificationLevel:(NCRoomNotificationLevel)level
{
    if (level == _room.notificationLevel) {
        return;
    }
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] setNotificationLevel:level forRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            [[NCRoomsManager sharedInstance] updateRoom:_room.token];
        } else {
            NSLog(@"Error setting room notification level: %@", error.description);
            [self.tableView reloadData];
            [self showRoomModificationError:kModificationErrorNotifications];
        }
    }];
}

- (void)showPasswordOptions
{
    NSString *alertTitle = _room.hasPassword ? @"Set new password:" : @"Set password:";
    UIAlertController *passwordDialog =
    [UIAlertController alertControllerWithTitle:alertTitle
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    __weak typeof(self) weakSelf = self;
    [passwordDialog addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Password";
        textField.secureTextEntry = YES;
        textField.delegate = weakSelf;
        textField.tag = k_set_password_textfield_tag;
    }];
    
    NSString *actionTitle = _room.hasPassword ? @"Change password" : @"OK";
    _setPasswordAction = [UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *password = [[passwordDialog textFields][0] text];
        NSString *trimmedPassword = [password stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [self setModifyingRoomUI];
        [[NCAPIController sharedInstance] setPassword:trimmedPassword toRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
            if (!error) {
                [[NCRoomsManager sharedInstance] updateRoom:_room.token];
            } else {
                NSLog(@"Error setting room password: %@", error.description);
                [self.tableView reloadData];
                [self showRoomModificationError:kModificationErrorPassword];
            }
        }];
    }];
    _setPasswordAction.enabled = NO;
    [passwordDialog addAction:_setPasswordAction];
    
    if (_room.hasPassword) {
        UIAlertAction *removePasswordAction = [UIAlertAction actionWithTitle:@"Remove password" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self setModifyingRoomUI];
            [[NCAPIController sharedInstance] setPassword:@"" toRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
                if (!error) {
                    [[NCRoomsManager sharedInstance] updateRoom:_room.token];
                } else {
                    NSLog(@"Error changing room password: %@", error.description);
                    [self.tableView reloadData];
                    [self showRoomModificationError:kModificationErrorPassword];
                }
            }];
        }];
        [passwordDialog addAction:removePasswordAction];
    }
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [passwordDialog addAction:cancelAction];
    
    [self presentViewController:passwordDialog animated:YES completion:nil];
}

- (void)makeRoomPublic
{
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] makeRoomPublic:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:kPublicActionPublicToggle inSection:[self getSectionForRoomInfoSection:kRoomInfoSectionPublic]];
            [self shareRoomLinkFromIndexPath:indexPath];
            [[NCRoomsManager sharedInstance] updateRoom:_room.token];
        } else {
            NSLog(@"Error making public the room: %@", error.description);
            [self.tableView reloadData];
            [self showRoomModificationError:kModificationErrorShare];
        }
        _publicSwtich.enabled = YES;
    }];
}

- (void)makeRoomPrivate
{
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] makeRoomPrivate:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            [[NCRoomsManager sharedInstance] updateRoom:_room.token];
        } else {
            NSLog(@"Error making private the room: %@", error.description);
            [self.tableView reloadData];
            [self showRoomModificationError:kModificationErrorShare];
        }
        _publicSwtich.enabled = YES;
    }];
}

- (void)shareRoomLinkFromIndexPath:(NSIndexPath *)indexPath
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    NSString *shareMessage = [NSString stringWithFormat:@"Join the conversation at %@/index.php/call/%@",
                              activeAccount.server, _room.token];
    if (_room.name && ![_room.name isEqualToString:@""]) {
        shareMessage = [NSString stringWithFormat:@"Join the conversation%@ at %@/index.php/call/%@",
                        [NSString stringWithFormat:@" \"%@\"", _room.name], activeAccount.server, _room.token];
    }
    NSArray *items = @[shareMessage];
    UIActivityViewController *controller = [[UIActivityViewController alloc]initWithActivityItems:items applicationActivities:nil];
    
    NSString *appDisplayName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
    NSString *emailSubject = [NSString stringWithFormat:@"%@ invitation", appDisplayName];
    [controller setValue:emailSubject forKey:@"subject"];
    
    // Presentation on iPads
    controller.popoverPresentationController.sourceView = self.tableView;
    controller.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    
    [self presentViewController:controller animated:YES completion:nil];
    
    controller.completionWithItemsHandler = ^(NSString *activityType,
                                              BOOL completed,
                                              NSArray *returnedItems,
                                              NSError *error) {
        if (error) {
            NSLog(@"An Error occured sharing room: %@, %@", error.localizedDescription, error.localizedFailureReason);
        }
    };
}

- (void)leaveRoom
{
    [[NCAPIController sharedInstance] removeSelfFromRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSInteger errorCode, NSError *error) {
        if (!error) {
            if (_chatViewController) {
                [_chatViewController leaveChat];
            }
            [[NCUserInterfaceController sharedInstance] presentConversationsList];
        } else if (errorCode == 400) {
            [self showRoomModificationError:kModificationErrorLeaveModeration];
        } else {
            NSLog(@"Error leaving the room: %@", error.description);
            [self showRoomModificationError:kModificationErrorLeave];
        }
    }];
}

- (void)deleteRoom
{
    [[NCAPIController sharedInstance] deleteRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            if (_chatViewController) {
                [_chatViewController leaveChat];
            }
            [[NCUserInterfaceController sharedInstance] presentConversationsList];
        } else {
            NSLog(@"Error deleting the room: %@", error.description);
            [self showRoomModificationError:kModificationErrorDelete];
        }
    }];
}

#pragma mark - Webinar options

- (void)enableLobby
{
    [self setLobbyState:NCRoomLobbyStateModeratorsOnly withTimer:0];
}

- (void)disableLobby
{
    [self setLobbyState:NCRoomLobbyStateAllParticipants withTimer:0];
}

- (void)setLobbyState:(NCRoomLobbyState)lobbyState withTimer:(NSInteger)timer
{
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] setLobbyState:lobbyState withTimer:timer forRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            [[NCRoomsManager sharedInstance] updateRoom:_room.token];
        } else {
            NSLog(@"Error changing lobby state in room: %@", error.description);
            [self.tableView reloadData];
            [self showRoomModificationError:kModificationErrorLobby];
        }
        _lobbySwtich.enabled = YES;
    }];
}

- (void)setLobbyDate
{
    NSInteger lobbyTimer = _lobbyDatePicker.date.timeIntervalSince1970;
    [self setLobbyState:NCRoomLobbyStateModeratorsOnly withTimer:lobbyTimer];
    
    NSString *lobbyTimerReadable = [NCUtils readableDateFromDate:_lobbyDatePicker.date];
    _lobbyDateTextField.text = [NSString stringWithFormat:@"%@",lobbyTimerReadable];
    [self dismissLobbyDatePicker];
}

- (void)removeLobbyDate
{
    [self setLobbyState:NCRoomLobbyStateModeratorsOnly withTimer:0];
    [self dismissLobbyDatePicker];
}

- (void)dismissLobbyDatePicker
{
    [_lobbyDateTextField resignFirstResponder];
}

- (void)setupLobbyDatePicker
{
    [_lobbyDatePicker setMinimumDate:[NSDate new]];
    // Round up default lobby timer to next hour
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components: NSCalendarUnitEra|NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour fromDate: [NSDate new]];
    [components setHour: [components hour] + 1];
    [_lobbyDatePicker setDate:[calendar dateFromComponents:components]];
    
    UIToolbar *toolBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(dismissLobbyDatePicker)];
    UIBarButtonItem *doneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(setLobbyDate)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    [toolBar setItems:[NSArray arrayWithObjects:cancelButton, space,doneButton, nil]];
    [_lobbyDateTextField setInputAccessoryView:toolBar];
    
    if (_room.lobbyTimer > 0) {
        NSDate *date = [[NSDate alloc] initWithTimeIntervalSince1970:_room.lobbyTimer];
        UIBarButtonItem *clearButton = [[UIBarButtonItem alloc] initWithTitle:@"Remove" style:UIBarButtonItemStylePlain target:self action:@selector(removeLobbyDate)];
        [clearButton setTintColor:[UIColor redColor]];
        [toolBar setItems:[NSArray arrayWithObjects:clearButton, space, doneButton, nil]];
        [_lobbyDatePicker setDate:date];
    }
}

#pragma mark - Participant options

- (void)addParticipantsButtonPressed
{
    AddParticipantsTableViewController *addParticipantsVC = [[AddParticipantsTableViewController alloc] initForRoom:_room];
    addParticipantsVC.delegate = self;
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:addParticipantsVC];
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void)addParticipantsTableViewControllerDidFinish:(AddParticipantsTableViewController *)viewController
{
    [self getRoomParticipants];
}

- (void)showModerationOptionsForParticipantAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoomParticipant *participant = [_roomParticipants objectAtIndex:indexPath.row];
    
    UIAlertController *optionsActionSheet =
    [UIAlertController alertControllerWithTitle:participant.displayName
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
    
    if (participant.participantType == kNCParticipantTypeModerator) {
        UIAlertAction *demoteFromModerator = [UIAlertAction actionWithTitle:@"Demote from moderator"
                                                                      style:UIAlertActionStyleDefault
                                                                    handler:^void (UIAlertAction *action) {
                                                                        [self demoteFromModerator:participant];
                                                                    }];
        [demoteFromModerator setValue:[[UIImage imageNamed:@"rename-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
        [optionsActionSheet addAction:demoteFromModerator];
    } else if (participant.participantType == kNCParticipantTypeUser) {
        UIAlertAction *promoteToModerator = [UIAlertAction actionWithTitle:@"Promote to moderator"
                                                                     style:UIAlertActionStyleDefault
                                                                   handler:^void (UIAlertAction *action) {
                                                                       [self promoteToModerator:participant];
                                                                   }];
        [promoteToModerator setValue:[[UIImage imageNamed:@"rename-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
        [optionsActionSheet addAction:promoteToModerator];
    }
    
    // Remove participant
    UIAlertAction *removeParticipant = [UIAlertAction actionWithTitle:@"Remove participant"
                                                                style:UIAlertActionStyleDestructive
                                                              handler:^void (UIAlertAction *action) {
                                                                  [self removeParticipant:participant];
                                                              }];
    [removeParticipant setValue:[[UIImage imageNamed:@"delete-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
    [optionsActionSheet addAction:removeParticipant];
    
    
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    optionsActionSheet.popoverPresentationController.sourceView = self.tableView;
    optionsActionSheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

- (void)promoteToModerator:(NCRoomParticipant *)participant
{
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] promoteParticipant:participant.participantId toModeratorOfRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            [self getRoomParticipants];
        } else {
            NSLog(@"Error promoting participant to moderator: %@", error.description);
            [self showRoomModificationError:kModificationErrorModeration];
        }
    }];
}

- (void)demoteFromModerator:(NCRoomParticipant *)participant
{
    [self setModifyingRoomUI];
    [[NCAPIController sharedInstance] demoteModerator:participant.participantId toParticipantOfRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (!error) {
            [self getRoomParticipants];
        } else {
            NSLog(@"Error demoting participant from moderator: %@", error.description);
            [self showRoomModificationError:kModificationErrorModeration];
        }
    }];
}

- (void)removeParticipant:(NCRoomParticipant *)participant
{
    if (participant.participantType == kNCParticipantTypeGuest) {
        [self setModifyingRoomUI];
        [[NCAPIController sharedInstance] removeGuest:participant.participantId fromRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
            if (!error) {
                [self getRoomParticipants];
            } else {
                NSLog(@"Error removing guest from room: %@", error.description);
                [self showRoomModificationError:kModificationErrorRemove];
            }
        }];
    } else {
        [self setModifyingRoomUI];
        [[NCAPIController sharedInstance] removeParticipant:participant.participantId fromRoom:_room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
            if (!error) {
                [self getRoomParticipants];
            } else {
                NSLog(@"Error removing participant from room: %@", error.description);
                [self showRoomModificationError:kModificationErrorRemove];
            }
        }];
    }
}


#pragma mark - Public switch

- (void)publicValueChanged:(id)sender
{
    _publicSwtich.enabled = NO;
    if (_publicSwtich.on) {
        [self makeRoomPublic];
    } else {
        [self makeRoomPrivate];
    }
}

#pragma mark - Lobby switch

- (void)lobbyValueChanged:(id)sender
{
    _lobbySwtich.enabled = NO;
    if (_lobbySwtich.on) {
        [self enableLobby];
    } else {
        [self disableLobby];
    }
}

#pragma mark - UIGestureRecognizer delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    // Allow click on tableview cells
    if ([touch.view isDescendantOfView:self.tableView]) {
        if (![touch.view isDescendantOfView:_roomNameTextField]) {
            [self dismissKeyboard];
        }
        return NO;
    }
    return YES;
}

#pragma mark - UITextField delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (textField == _roomNameTextField) {
        [self renameRoom];
    }
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (textField == _roomNameTextField || textField.tag == k_set_password_textfield_tag) {
        // Prevent crashing undo bug
        // https://stackoverflow.com/questions/433337/set-the-maximum-character-length-of-a-uitextfield
        if (range.length + range.location > textField.text.length) {
            return NO;
        }
        // Set maximum character length
        NSUInteger newLength = [textField.text length] + [string length] - range.length;
        BOOL hasAllowedLength = newLength <= 200;
        // Enable/Disable password confirmation button
        if (hasAllowedLength) {
            NSString *newValue = [[textField.text stringByReplacingCharactersInRange:range withString:string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            _setPasswordAction.enabled = (newValue.length > 0);
        }
        return hasAllowedLength;
    }
    return YES;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [self getRoomInfoSections].count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSArray *sections = [self getRoomInfoSections];
    RoomInfoSection infoSection = [[sections objectAtIndex:section] intValue];
    switch (infoSection) {
        case kRoomInfoSectionActions:
            return [self getRoomActions].count;
            break;
            
        case kRoomInfoSectionPublic:
            return [self getPublicActions].count;
            break;
            
        case kRoomInfoSectionWebinar:
            return [self getWebinarActions].count;
            break;
            
        case kRoomInfoSectionParticipants:
            return _roomParticipants.count;
            break;
            
        case kRoomInfoSectionDestructive:
            return [self getRoomDestructiveActions].count;
            break;
        default:
            break;
    }
    
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *sections = [self getRoomInfoSections];
    RoomInfoSection infoSection = [[sections objectAtIndex:indexPath.section] intValue];
    switch (infoSection) {
        case kRoomInfoSectionName:
            return 80;
            break;
        case kRoomInfoSectionParticipants:
            return kContactsTableCellHeight;
            break;
        default:
            break;
    }
    return 48;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSArray *sections = [self getRoomInfoSections];
    RoomInfoSection infoSection = [[sections objectAtIndex:section] intValue];
    switch (infoSection) {
        case kRoomInfoSectionPublic:
            return @"Guests";
            break;
        case kRoomInfoSectionWebinar:
            return @"Webinar";
            break;
        default:
            break;
    }
    
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    NSArray *sections = [self getRoomInfoSections];
    RoomInfoSection infoSection = [[sections objectAtIndex:section] intValue];
    switch (infoSection) {
        case kRoomInfoSectionParticipants:
        {
            NSString *title = [NSString stringWithFormat:@"%lu participants", (unsigned long)_roomParticipants.count];
            if (_roomParticipants.count == 1) {
                title = @"1 participant";
            }
            _headerView.label.text = [title uppercaseString];
            _headerView.button.hidden = (_room.canModerate) ? NO : YES;
            return _headerView;
        }
            break;
        default:
            break;
    }
    
    return nil;
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kRoomInfoSectionActions:
            return 10;
            break;
        case kRoomInfoSectionPublic:
        case kRoomInfoSectionWebinar:
            return 36;
            break;
        case kRoomInfoSectionParticipants:
            return 40;
            break;
    }
    
    return 25;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = nil;
    static NSString *favoriteRoomCellIdentifier = @"FavoriteRoomCellIdentifier";
    static NSString *notificationLevelCellIdentifier = @"NotificationLevelCellIdentifier";
    static NSString *shareLinkCellIdentifier = @"ShareLinkCellIdentifier";
    static NSString *passwordCellIdentifier = @"PasswordCellIdentifier";
    static NSString *sendLinkCellIdentifier = @"SendLinkCellIdentifier";
    static NSString *lobbyCellIdentifier = @"LobbyCellIdentifier";
    static NSString *lobbyTimerCellIdentifier = @"LobbyTimerCellIdentifier";
    static NSString *leaveRoomCellIdentifier = @"LeaveRoomCellIdentifier";
    static NSString *deleteRoomCellIdentifier = @"DeleteRoomCellIdentifier";
    
    NSArray *sections = [self getRoomInfoSections];
    RoomInfoSection section = [[sections objectAtIndex:indexPath.section] intValue];
    switch (section) {
        case kRoomInfoSectionName:
        {
            RoomNameTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRoomNameCellIdentifier];
            if (!cell) {
                cell = [[RoomNameTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kRoomNameCellIdentifier];
            }
            
            cell.roomNameTextField.text = _room.name;
            
            switch (_room.type) {
                case kNCRoomTypeOneToOne:
                {
                    cell.roomNameTextField.text = _room.displayName;
                    [cell.roomImage setImageWithURLRequest:[[NCAPIController sharedInstance] createAvatarRequestForUser:_room.name andSize:96 usingAccount:[[NCDatabaseManager sharedInstance] activeAccount]]
                                          placeholderImage:nil success:nil failure:nil];
                }
                    break;
                    
                case kNCRoomTypeGroup:
                    [cell.roomImage setImage:[UIImage imageNamed:@"group-bg"]];
                    break;
                    
                case kNCRoomTypePublic:
                    [cell.roomImage setImage:(_room.hasPassword) ? [UIImage imageNamed:@"public-password-bg"] : [UIImage imageNamed:@"public-bg"]];
                    break;
                    
                case kNCRoomTypeChangelog:
                {
                    cell.roomNameTextField.text = _room.displayName;
                    [cell.roomImage setImage:[UIImage imageNamed:@"changelog"]];
                }
                    break;
                    
                case kNCRoomTypeNotes:
                {
                    cell.roomNameTextField.text = _room.displayName;
                    [cell.roomImage setImage:[UIImage imageNamed:@"notes"]];
                }
                    break;
                    
                default:
                    break;
            }
            
            // Set objectType image
            if ([_room.objectType isEqualToString:NCRoomObjectTypeFile]) {
                [cell.roomImage setImage:[UIImage imageNamed:@"file-bg"]];
            } else if ([_room.objectType isEqualToString:NCRoomObjectTypeSharePassword]) {
                [cell.roomImage setImage:[UIImage imageNamed:@"password-bg"]];
            }
            
            if (_room.isNameEditable) {
                _roomNameTextField = cell.roomNameTextField;
                _roomNameTextField.delegate = self;
                [_roomNameTextField setReturnKeyType:UIReturnKeyDone];
                cell.userInteractionEnabled = YES;
            } else {
                _roomNameTextField = nil;
                cell.userInteractionEnabled = NO;
            }
            
            if (_room.isFavorite) {
                [cell.favoriteImage setImage:[UIImage imageNamed:@"favorite-room"]];
            }
            
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            
            return cell;
        }
            break;
        case kRoomInfoSectionActions:
        {
            NSArray *actions = [self getRoomActions];
            RoomAction action = [[actions objectAtIndex:indexPath.row] intValue];
            switch (action) {
                case kRoomActionFavorite:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:favoriteRoomCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:favoriteRoomCellIdentifier];
                    }
                    
                    cell.textLabel.text = (_room.isFavorite) ? @"Remove from favorites" : @"Add to favorites";
                    [cell.imageView setImage:(_room.isFavorite) ? [UIImage imageNamed:@"fav-off-setting"] : [UIImage imageNamed:@"fav-setting"]];
                    
                    return cell;
                }
                    break;
                case kRoomActionNotifications:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:notificationLevelCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:notificationLevelCellIdentifier];
                    }
                    
                    cell.textLabel.text = @"Notifications";
                    cell.detailTextLabel.text = _room.notificationLevelString;
                    [cell.imageView setImage:[UIImage imageNamed:@"notifications-settings"]];
                    
                    return cell;
                }
                    break;
                case kRoomActionSendLink:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:sendLinkCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:sendLinkCellIdentifier];
                    }
                    
                    cell.textLabel.text = @"Send conversation link";
                    [cell.imageView setImage:[UIImage imageNamed:@"share-settings"]];
                    
                    return cell;
                }
                    break;
            }
        }
            break;
        case kRoomInfoSectionPublic:
        {
            NSArray *actions = [self getPublicActions];
            PublicAction action = [[actions objectAtIndex:indexPath.row] intValue];
            switch (action) {
                case kPublicActionPublicToggle:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:shareLinkCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:shareLinkCellIdentifier];
                    }
                    
                    cell.textLabel.text = @"Share link";
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.accessoryView = _publicSwtich;
                    _publicSwtich.on = (_room.type == kNCRoomTypePublic) ? YES : NO;
                    [cell.imageView setImage:[UIImage imageNamed:@"public-setting"]];
                    
                    return cell;
                }
                    break;
                    
                case kPublicActionPassword:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:passwordCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:passwordCellIdentifier];
                    }
                    
                    cell.textLabel.text = (_room.hasPassword) ? @"Change password" : @"Set password";
                    [cell.imageView setImage:(_room.hasPassword) ? [UIImage imageNamed:@"password-settings"] : [UIImage imageNamed:@"no-password-settings"]];
                    
                    return cell;
                }
                    break;
            }
        }
            break;
        case kRoomInfoSectionWebinar:
        {
            NSArray *actions = [self getWebinarActions];
            WebinarAction action = [[actions objectAtIndex:indexPath.row] intValue];
            switch (action) {
                case kWebinarActionLobby:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:lobbyCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:lobbyCellIdentifier];
                    }
                    
                    cell.textLabel.text = @"Lobby";
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.accessoryView = _lobbySwtich;
                    _lobbySwtich.on = (_room.lobbyState == NCRoomLobbyStateModeratorsOnly) ? YES : NO;
                    [cell.imageView setImage:[UIImage imageNamed:@"lobby"]];
                    
                    return cell;
                }
                    break;
                case kWebinarActionLobbyTimer:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:lobbyTimerCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:lobbyTimerCellIdentifier];
                    }
                    
                    cell.textLabel.text = @"Start time";
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.accessoryView = _lobbyDateTextField;
                    NSDate *date = [[NSDate alloc] initWithTimeIntervalSince1970:_room.lobbyTimer];
                    _lobbyDateTextField.text = _room.lobbyTimer > 0 ? [NCUtils readableDateFromDate:date] : nil;
                    [cell.imageView setImage:[UIImage imageNamed:@"timer"]];
                    
                    return cell;
                }
                    break;
            }
        }
            break;
        case kRoomInfoSectionParticipants:
        {
            NCRoomParticipant *participant = [_roomParticipants objectAtIndex:indexPath.row];
            ContactsTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kContactCellIdentifier forIndexPath:indexPath];
            if (!cell) {
                cell = [[ContactsTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kContactCellIdentifier];
            }
            
            // Display name
            cell.labelTitle.text = participant.displayName;
            
            // Avatar
            if (participant.participantType == kNCParticipantTypeGuest) {
                UIColor *guestAvatarColor = [UIColor colorWithRed:0.84 green:0.84 blue:0.84 alpha:1.0]; /*#d5d5d5*/
                NSString *avatarName = ([participant.displayName isEqualToString:@""]) ? @"?" : participant.displayName;
                NSString *guestName = ([participant.displayName isEqualToString:@""]) ? @"Guest" : participant.displayName;
                cell.labelTitle.text = guestName;
                [cell.contactImage setImageWithString:avatarName color:guestAvatarColor circular:true];
            } else {
                [cell.contactImage setImageWithURLRequest:[[NCAPIController sharedInstance] createAvatarRequestForUser:participant.userId andSize:96 usingAccount:[[NCDatabaseManager sharedInstance] activeAccount]]
                                         placeholderImage:nil success:nil failure:nil];
            }
            
            // Online status
            if (participant.isOffline) {
                cell.contactImage.alpha = 0.5;
                cell.labelTitle.alpha = 0.5;
            } else {
                cell.contactImage.alpha = 1;
                cell.labelTitle.alpha = 1;
            }
            
            // InCall status
            if (participant.inCall) {
                cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"videocall-indicator"]];
            } else {
                cell.accessoryView = nil;
            }
            
            cell.layoutMargins = UIEdgeInsetsMake(0, 72, 0, 0);
            
            [cell setUserStatus:participant.status];
            
            return cell;
        }
            break;
        case kRoomInfoSectionDestructive:
        {
            NSArray *actions = [self getRoomDestructiveActions];
            DestructiveAction action = [[actions objectAtIndex:indexPath.row] intValue];
            switch (action) {
                case kDestructiveActionLeave:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:leaveRoomCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:leaveRoomCellIdentifier];
                    }
                    
                    cell.textLabel.text = @"Leave conversation";
                    cell.textLabel.textColor = [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0]; //#FF3B30
                    [cell.imageView setImage:[UIImage imageNamed:@"exit-action"]];
                    
                    return cell;
                }
                    break;
                case kDestructiveActionDelete:
                {
                    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:deleteRoomCellIdentifier];
                    if (!cell) {
                        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:deleteRoomCellIdentifier];
                    }
                    
                    cell.textLabel.text = @"Delete conversation";
                    cell.textLabel.textColor = [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0]; //#FF3B30
                    [cell.imageView setImage:[UIImage imageNamed:@"delete-action"]];
                    
                    return cell;
                }
                    break;
            }
        }
            break;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *sections = [self getRoomInfoSections];
    RoomInfoSection section = [[sections objectAtIndex:indexPath.section] intValue];
    switch (section) {
        case kRoomInfoSectionName:
            break;
        case kRoomInfoSectionActions:
        {
            NSArray *actions = [self getRoomActions];
            RoomAction action = [[actions objectAtIndex:indexPath.row] intValue];
            switch (action) {
                case kRoomActionFavorite:
                    if (_room.isFavorite) {
                        [self removeRoomFromFavorites];
                    } else {
                        [self addRoomToFavorites];
                    }
                    break;
                case kRoomActionNotifications:
                    [self presentNotificationLevelSelector];
                    break;
                case kRoomActionSendLink:
                    [self shareRoomLinkFromIndexPath:indexPath];
                    break;
            }
        }
            break;
        case kRoomInfoSectionPublic:
        {
            NSArray *actions = [self getPublicActions];
            PublicAction action = [[actions objectAtIndex:indexPath.row] intValue];
            switch (action) {
                case kPublicActionPassword:
                    [self showPasswordOptions];
                    break;
                default:
                    break;
            }
        }
            break;
        case kRoomInfoSectionWebinar:
            break;
        case kRoomInfoSectionParticipants:
        {
            NCRoomParticipant *participant = [_roomParticipants objectAtIndex:indexPath.row];
            if (participant.participantType != kNCParticipantTypeOwner && ![self isAppUser:participant] && _room.canModerate) {
                [self showModerationOptionsForParticipantAtIndexPath:indexPath];
            }
        }
            break;
        case kRoomInfoSectionDestructive:
        {
            NSArray *actions = [self getRoomDestructiveActions];
            DestructiveAction action = [[actions objectAtIndex:indexPath.row] intValue];
            [self showConfirmationDialogForDestructiveAction:action];
        }
            break;
    }
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
