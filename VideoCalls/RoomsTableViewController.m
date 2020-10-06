//
//  RoomsTableViewController.m
//  VideoCalls
//
//  Created by Ivan Sein on 27.06.17.
//  Copyright © 2017 struktur AG. All rights reserved.
//

#import "RoomsTableViewController.h"

#import <Realm/Realm.h>

#import "AFNetworking.h"
#import "RoomTableViewCell.h"
#import "CCCertificate.h"
#import "FTPopOverMenu.h"
#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCDatabaseManager.h"
#import "NCImageSessionManager.h"
#import "NCConnectionController.h"
#import "NCNotificationController.h"
#import "NCSettingsController.h"
#import "NCUserInterfaceController.h"
#import "NCUtils.h"
#import "NSDate+DateTools.h"
#import "AFImageDownloader.h"
#import "UIImageView+AFNetworking.h"
#import "UIButton+AFNetworking.h"
#import "NCChatViewController.h"
#import "NCRoomsManager.h"
#import "NewRoomTableViewController.h"
#import "RoomInfoTableViewController.h"
#import "RoomSearchTableViewController.h"
#import "SettingsViewController.h"
#import "PlaceholderView.h"
#import "UIBarButtonItem+Badge.h"

typedef void (^FetchRoomsCompletionBlock)(BOOL success);

@interface RoomsTableViewController () <CCCertificateDelegate, UISearchBarDelegate, UISearchControllerDelegate, UISearchResultsUpdating>
{
    RLMNotificationToken *_rlmNotificationToken;
    NSMutableArray *_rooms;
    UIRefreshControl *_refreshControl;
    BOOL _allowEmptyGroupRooms;
    UISearchController *_searchController;
    RoomSearchTableViewController *_resultTableViewController;
    PlaceholderView *_roomsBackgroundView;
    UIBarButtonItem *_settingsButton;
    UINavigationController *_settingsNC;
}

@end

@implementation RoomsTableViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    __weak typeof(self) weakSelf = self;
    _rlmNotificationToken = [[RLMRealm defaultRealm] addNotificationBlock:^(NSString *notification, RLMRealm * realm) {
        [weakSelf refreshRoomList];
    }];
    
    [self.tableView registerNib:[UINib nibWithNibName:kRoomTableCellNibName bundle:nil] forCellReuseIdentifier:kRoomCellIdentifier];
    // Align header's title to ContactsTableViewCell's label
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 72, 0, 0);
    
    self.addButton.accessibilityLabel = @"Create a new conversation";
    self.addButton.accessibilityHint = @"Double tap to create group, public or one to one conversations.";
    
    [self createRefreshControl];
    [self setNavigationLogoButton];
    
    [UIImageView setSharedImageDownloader:[[NCAPIController sharedInstance] imageDownloader]];
    [UIButton setSharedImageDownloader:[[NCAPIController sharedInstance] imageDownloader]];
    
    self.navigationController.navigationBar.barTintColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
    self.tabBarController.tabBar.tintColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
    
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    
    _resultTableViewController = [[RoomSearchTableViewController alloc] init];
    _searchController = [[UISearchController alloc] initWithSearchResultsController:_resultTableViewController];
    _searchController.searchResultsUpdater = self;
    [_searchController.searchBar sizeToFit];
    
    if (@available(iOS 13.0, *)) {
        UIColor *themeColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = themeColor;
        self.navigationItem.standardAppearance = appearance;
        self.navigationItem.compactAppearance = appearance;
        self.navigationItem.scrollEdgeAppearance = appearance;

        self.navigationItem.searchController = _searchController;
        self.navigationItem.searchController.searchBar.searchTextField.backgroundColor = [NCUtils darkerColorFromColor:themeColor];
        _searchController.searchBar.tintColor = [UIColor whiteColor];
        UITextField *searchTextField = [_searchController.searchBar valueForKey:@"searchField"];
        searchTextField.tintColor = [UIColor whiteColor];
        searchTextField.textColor = [UIColor whiteColor];
        dispatch_async(dispatch_get_main_queue(), ^{
            searchTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search"
            attributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:0.5]}];
        });
    } else if (@available(iOS 11.0, *)) {
        self.navigationItem.searchController = _searchController;
        _searchController.searchBar.tintColor = [UIColor whiteColor];
        UITextField *searchTextField = [_searchController.searchBar valueForKey:@"searchField"];
        searchTextField.tintColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
        UIView *backgroundview = [searchTextField.subviews firstObject];
        backgroundview.backgroundColor = [UIColor whiteColor];
        backgroundview.layer.cornerRadius = 8;
        backgroundview.clipsToBounds = YES;
    } else {
        self.tableView.tableHeaderView = _searchController.searchBar;
        _searchController.searchBar.barTintColor = [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0]; //efeff4
        _searchController.searchBar.layer.borderWidth = 1;
        _searchController.searchBar.layer.borderColor = [[UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0] CGColor];
    }
    
    // We want ourselves to be the delegate for the result table so didSelectRowAtIndexPath is called for both tables.
    _resultTableViewController.tableView.delegate = self;
    _searchController.delegate = self;
    _searchController.searchBar.delegate = self;
    
    self.definesPresentationContext = YES;
    
    // Rooms placeholder view
    _roomsBackgroundView = [[PlaceholderView alloc] init];
    [_roomsBackgroundView.placeholderImage setImage:[UIImage imageNamed:@"conversations-placeholder"]];
    [_roomsBackgroundView.placeholderText setText:@"You are not part of any conversation. Press + to start a new one."];
    [_roomsBackgroundView.placeholderView setHidden:YES];
    [_roomsBackgroundView.loadingView startAnimating];
    self.tableView.backgroundView = _roomsBackgroundView;
    
    // Settings navigation controller
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    _settingsNC = [storyboard instantiateViewControllerWithIdentifier:@"settingsNC"];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appStateHasChanged:) name:NCAppStateHasChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectionStateHasChanged:) name:NCConnectionStateHasChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(roomsDidUpdate:) name:NCRoomsManagerDidUpdateRoomsNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notificationWillBePresented:) name:NCNotificationControllerWillPresentNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userProfileImageUpdated:) name:NCUserProfileImageUpdatedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)dealloc
{
    [_rlmNotificationToken invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self adaptInterfaceForAppState:[NCConnectionController sharedInstance].appState];
    [self adaptInterfaceForConnectionState:[NCConnectionController sharedInstance].connectionState];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self refreshRoomList];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Notifications

- (void)appStateHasChanged:(NSNotification *)notification
{
    AppState appState = [[notification.userInfo objectForKey:@"appState"] intValue];
    [self adaptInterfaceForAppState:appState];
}

- (void)connectionStateHasChanged:(NSNotification *)notification
{
    ConnectionState connectionState = [[notification.userInfo objectForKey:@"connectionState"] intValue];
    [self adaptInterfaceForConnectionState:connectionState];
}

- (void)roomsDidUpdate:(NSNotification *)notification
{
    NSError *error = [notification.userInfo objectForKey:@"error"];
    if (error) {
        NSLog(@"Error while trying to get rooms: %@", error);
        if ([error code] == NSURLErrorServerCertificateUntrusted) {
            NSLog(@"Untrusted certificate");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[CCCertificate sharedManager] presentViewControllerCertificateWithTitle:[error localizedDescription] viewController:self delegate:self];
            });
            
        }
    }
    
    [_refreshControl endRefreshing];
}

- (void)notificationWillBePresented:(NSNotification *)notification
{
    [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:NO];
    [self setUnreadMessageForInactiveAccountsIndicator];
}

- (void)userProfileImageUpdated:(NSNotification *)notification
{
    [self setProfileButton];
}

- (void)appWillEnterForeground:(NSNotification *)notification
{
    if ([NCConnectionController sharedInstance].appState == kAppStateReady) {
        [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:YES];
        [self setUnreadMessageForInactiveAccountsIndicator];
    }
}

#pragma mark - Interface Builder Actions

- (IBAction)addButtonPressed:(id)sender
{
    NewRoomTableViewController *newRoowVC = [[NewRoomTableViewController alloc] init];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:newRoowVC];
    [self presentViewController:navigationController animated:YES completion:nil];
}

#pragma mark - Refresh Control

- (void)createRefreshControl
{
    _refreshControl = [UIRefreshControl new];
    if (@available(iOS 11.0, *)) {
        _refreshControl.tintColor = [UIColor whiteColor];
    } else {
        _refreshControl.tintColor = [UIColor colorWithWhite:0 alpha:0.3];
        _refreshControl.backgroundColor = [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0]; //efeff4
    }
    [_refreshControl addTarget:self action:@selector(refreshControlTarget) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = _refreshControl;
}

- (void)deleteRefreshControl
{
    [_refreshControl endRefreshing];
    self.refreshControl = nil;
}

- (void)refreshControlTarget
{
    [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:YES];
    // Actuate `Peek` feedback (weak boom)
    AudioServicesPlaySystemSound(1519);
}

#pragma mark - Title menu

- (void)setNavigationLogoButton
{
    UIImage *logoImage = [UIImage imageNamed:@"navigationLogo"];
    if (multiAccountEnabled) {
        UIButton *logoButton = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
        [logoButton setImage:logoImage forState:UIControlStateNormal];
        [logoButton addTarget:self action:@selector(showAccountsMenu:) forControlEvents:UIControlEventTouchUpInside];
        self.navigationItem.titleView = logoButton;
    } else {
        self.navigationItem.titleView = [[UIImageView alloc] initWithImage:logoImage];
    }
    self.navigationItem.titleView.accessibilityLabel = @"Nextcloud Talk";
    self.navigationItem.titleView.accessibilityHint = @"Double tap to change accounts or add a new one.";
}

-(void)showAccountsMenu:(UIButton*)sender
{
    NSMutableArray *menuArray = [NSMutableArray new];
    NSMutableArray *actionsArray = [NSMutableArray new];
    for (TalkAccount *talkAccount in [TalkAccount allObjects]) {
        TalkAccount *account = [[TalkAccount alloc] initWithValue:talkAccount];
        NSString *accountName = account.userDisplayName;
        UIImage *accountImage = [[NCAPIController sharedInstance] userProfileImageForAccount:account withSize:CGSizeMake(72, 72)];
        UIImageView *accessoryImageView = (account.active) ? [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"checkbox-checked"]] : nil;
        FTPopOverMenuModel *accountModel = [[FTPopOverMenuModel alloc] initWithTitle:accountName image:accountImage selected:NO accessoryView:accessoryImageView];
        [menuArray addObject:accountModel];
        [actionsArray addObject:account];
    }
    FTPopOverMenuModel *addAccountModel = [[FTPopOverMenuModel alloc] initWithTitle:@"Add account" image:[UIImage imageNamed:@"add-settings"] selected:NO accessoryView:nil];
    [menuArray addObject:addAccountModel];
    [actionsArray addObject:@"AddAccountAction"];
    
    FTPopOverMenuConfiguration *menuConfiguration = [[FTPopOverMenuConfiguration alloc] init];
    menuConfiguration.menuIconMargin = 12;
    menuConfiguration.menuTextMargin = 12;
    menuConfiguration.imageSize = CGSizeMake(24, 24);
    menuConfiguration.separatorInset = UIEdgeInsetsMake(0, 48, 0, 0);
    menuConfiguration.menuRowHeight = 44;
    menuConfiguration.autoMenuWidth = YES;
    menuConfiguration.textColor = [UIColor darkTextColor];
    menuConfiguration.textFont = [UIFont systemFontOfSize:15];
    menuConfiguration.backgroundColor = [UIColor whiteColor];
    menuConfiguration.borderWidth = 0;
    menuConfiguration.separatorColor = [UIColor colorWithWhite:0.85 alpha:1];
    menuConfiguration.shadowOpacity = 0.8;
    menuConfiguration.roundedImage = YES;
    menuConfiguration.defaultSelection = YES;

    [FTPopOverMenu showForSender:sender
                   withMenuArray:menuArray
                      imageArray:nil
                   configuration:menuConfiguration
                       doneBlock:^(NSInteger selectedIndex) {
                           id action = [actionsArray objectAtIndex:selectedIndex];
                           if ([action isKindOfClass:[TalkAccount class]]) {
                               TalkAccount *account = action;
                               [[NCSettingsController sharedInstance] setActiveAccountWithAccountId:account.accountId];
                           } else {
                               [[NCUserInterfaceController sharedInstance] presentLoginViewController];
                           }
                       } dismissBlock:nil];
}

#pragma mark - Search controller

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self searchForRoomsWithString:_searchController.searchBar.text];
}

- (void)searchForRoomsWithString:(NSString *)searchString
{
    _resultTableViewController.rooms = [self filterRoomsWithString:searchString];
    [_resultTableViewController.tableView reloadData];
}

- (NSArray *)filterRoomsWithString:(NSString *)searchString
{
    NSPredicate *sPredicate = [NSPredicate predicateWithFormat:@"displayName CONTAINS[c] %@", searchString];
    return [_rooms filteredArrayUsingPredicate:sPredicate];
}

#pragma mark - User Interface

- (void)refreshRoomList
{
    TalkAccount *account = [[NCDatabaseManager sharedInstance] activeAccount];
    NSArray *accountRooms = [[NCRoomsManager sharedInstance] roomsForAccountId:account.accountId witRealm:nil];
    _rooms = [[NSMutableArray alloc] initWithArray:accountRooms];
    
    // Show/Hide placeholder view
    [_roomsBackgroundView.loadingView stopAnimating];
    [_roomsBackgroundView.loadingView setHidden:YES];
    [_roomsBackgroundView.placeholderView setHidden:(_rooms.count > 0)];
    
    // Reload search controller if active
    if (_searchController.isActive) {
        [self searchForRoomsWithString:_searchController.searchBar.text];
    }
    
    // Reload room list
    [self.tableView reloadData];
}

- (void)adaptInterfaceForAppState:(AppState)appState
{
    switch (appState) {
        case kAppStateNotServerProvided:
        case kAppStateMissingUserProfile:
        case kAppStateMissingServerCapabilities:
        case kAppStateMissingSignalingConfiguration:
        {
            [self setProfileButton];
        }
            break;
        case kAppStateReady:
        {
            [self setProfileButton];
            BOOL isAppActive = [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive;
            [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:isAppActive];
        }
            break;
            
        default:
            break;
    }
}

- (void)adaptInterfaceForConnectionState:(ConnectionState)connectionState
{
    switch (connectionState) {
        case kConnectionStateConnected:
        {
            [self setOnlineAppearance];
        }
            break;
            
        case kConnectionStateDisconnected:
        {
            [self setOfflineAppearance];
        }
            break;
            
        default:
            break;
    }
}

- (void)setOfflineAppearance
{
    self.addButton.enabled = NO;
    self.navigationItem.titleView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"navigationLogoOffline"]];
}

- (void)setOnlineAppearance
{
    self.addButton.enabled = YES;
    [self setNavigationLogoButton];
}

#pragma mark - User profile

- (void)setProfileButton
{
    UIButton *profileButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [profileButton addTarget:self action:@selector(showUserProfile) forControlEvents:UIControlEventTouchUpInside];
    profileButton.frame = CGRectMake(0, 0, 30, 30);
    profileButton.accessibilityLabel = @"User profile and settings";
    profileButton.accessibilityHint = @"Double tap to go to user profile and application settings";
    
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    UIImage *profileImage = [[NCAPIController sharedInstance] userProfileImageForAccount:activeAccount withSize:CGSizeMake(90, 90)];
    if (profileImage) {
        UIGraphicsBeginImageContextWithOptions(profileButton.bounds.size, NO, 3.0);
        [[UIBezierPath bezierPathWithRoundedRect:profileButton.bounds cornerRadius:profileButton.bounds.size.height] addClip];
        [profileImage drawInRect:profileButton.bounds];
        profileImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        [profileButton setImage:profileImage forState:UIControlStateNormal];
    } else {
        [profileButton setImage:[UIImage imageNamed:@"settings-white"] forState:UIControlStateNormal];
        profileButton.contentMode = UIViewContentModeCenter;
    }
    
    _settingsButton = [[UIBarButtonItem alloc] initWithCustomView:profileButton];
    [self setUnreadMessageForInactiveAccountsIndicator];
    
    if (@available(iOS 11.0, *)) {
        NSLayoutConstraint *width = [_settingsButton.customView.widthAnchor constraintEqualToConstant:30];
        width.active = YES;
        NSLayoutConstraint *height = [_settingsButton.customView.heightAnchor constraintEqualToConstant:30];
        height.active = YES;
    }
    
    [self.navigationItem setLeftBarButtonItem:_settingsButton];
}

- (void)setUnreadMessageForInactiveAccountsIndicator
{
    NSInteger numberOfInactiveAccountsWithUnreadNotifications = [[NCDatabaseManager sharedInstance] numberOfInactiveAccountsWithUnreadNotifications];
    if (numberOfInactiveAccountsWithUnreadNotifications > 0) {
        _settingsButton.badgeValue = [NSString stringWithFormat:@"%ld", numberOfInactiveAccountsWithUnreadNotifications];
    }
}

- (void)showUserProfile
{
    [[NCDatabaseManager sharedInstance] removeUnreadNotificationForInactiveAccounts];
    [self setUnreadMessageForInactiveAccountsIndicator];
    [self presentViewController:_settingsNC animated:YES completion:nil];
}

#pragma mark - CCCertificateDelegate

- (void)trustedCerticateAccepted
{
    [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:NO];
}

#pragma mark - Room actions

- (void)setNotificationLevelForRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    UIAlertController *optionsActionSheet =
    [UIAlertController alertControllerWithTitle:@"Notifications"
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
    [optionsActionSheet addAction:[self actionForNotificationLevel:kNCRoomNotificationLevelAlways forRoom:room]];
    [optionsActionSheet addAction:[self actionForNotificationLevel:kNCRoomNotificationLevelMention forRoom:room]];
    [optionsActionSheet addAction:[self actionForNotificationLevel:kNCRoomNotificationLevelNever forRoom:room]];
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    optionsActionSheet.popoverPresentationController.sourceView = self.tableView;
    optionsActionSheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

- (UIAlertAction *)actionForNotificationLevel:(NCRoomNotificationLevel)level forRoom:(NCRoom *)room
{
    UIAlertAction *action = [UIAlertAction actionWithTitle:[room stringForNotificationLevel:level]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^void (UIAlertAction *action) {
                                                       if (level == room.notificationLevel) {
                                                           return;
                                                       }
                                                       [[NCAPIController sharedInstance] setNotificationLevel:level forRoom:room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
                                                           if (error) {
                                                               NSLog(@"Error renaming the room: %@", error.description);
                                                           }
                                                           [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:YES];
                                                       }];
                                                   }];
    if (room.notificationLevel == level) {
        [action setValue:[[UIImage imageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
    }
    return action;
}

- (void)shareLinkFromRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    NSString *shareMessage = [NSString stringWithFormat:@"Join the conversation at %@/index.php/call/%@",
                              activeAccount.server, room.token];
    if (room.name && ![room.name isEqualToString:@""]) {
        shareMessage = [NSString stringWithFormat:@"Join the conversation%@ at %@/index.php/call/%@",
                        [NSString stringWithFormat:@" \"%@\"", room.name], activeAccount.server, room.token];
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

- (void)addRoomToFavoritesAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    [[NCAPIController sharedInstance] addRoomToFavorites:room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (error) {
            NSLog(@"Error adding room to favorites: %@", error.description);
        }
        [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:YES];
    }];
}

- (void)removeRoomFromFavoritesAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    [[NCAPIController sharedInstance] removeRoomFromFavorites:room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
        if (error) {
            NSLog(@"Error removing room from favorites: %@", error.description);
        }
        [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:YES];
    }];
}

- (void)presentRoomInfoForRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    RoomInfoTableViewController *roomInfoVC = [[RoomInfoTableViewController alloc] initForRoom:room];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:roomInfoVC];
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void)leaveRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    UIAlertController *confirmDialog =
    [UIAlertController alertControllerWithTitle:@"Leave conversation"
                                        message:@"Do you really want to leave this conversation?"
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"Leave" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [_rooms removeObjectAtIndex:indexPath.row];
        [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
        [[NCAPIController sharedInstance] removeSelfFromRoom:room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSInteger errorCode, NSError *error) {
            if (errorCode == 400) {
                [self showLeaveRoomLastModeratorErrorForRoom:room];
            } else if (error) {
                NSLog(@"Error leaving room: %@", error.description);
            }
            [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:YES];
        }];
    }];
    [confirmDialog addAction:confirmAction];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [confirmDialog addAction:cancelAction];
    [self presentViewController:confirmDialog animated:YES completion:nil];
}

- (void)deleteRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    UIAlertController *confirmDialog =
    [UIAlertController alertControllerWithTitle:@"Delete conversation"
                                        message:room.deletionMessage
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [_rooms removeObjectAtIndex:indexPath.row];
        [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
        [[NCAPIController sharedInstance] deleteRoom:room.token forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSError *error) {
            if (error) {
                NSLog(@"Error deleting room: %@", error.description);
            }
            [[NCRoomsManager sharedInstance] updateRoomsUpdatingUserStatus:YES];
        }];
    }];
    [confirmDialog addAction:confirmAction];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [confirmDialog addAction:cancelAction];
    [self presentViewController:confirmDialog animated:YES completion:nil];
}

- (void)presentMoreActionsForRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    UIAlertController *optionsActionSheet =
    [UIAlertController alertControllerWithTitle:room.displayName
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add/Remove room to/from favorites
    UIAlertAction *favoriteAction = [UIAlertAction actionWithTitle:(room.isFavorite) ? @"Remove from favorites" : @"Add to favorites"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^void (UIAlertAction *action) {
                                                               if (room.isFavorite) {
                                                                   [self removeRoomFromFavoritesAtIndexPath:indexPath];
                                                               } else {
                                                                   [self addRoomToFavoritesAtIndexPath:indexPath];
                                                               }
                                                           }];
    NSString *favImageName = (room.isFavorite) ? @"favorite-action" : @"fav-setting";
    [favoriteAction setValue:[[UIImage imageNamed:favImageName] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
    [optionsActionSheet addAction:favoriteAction];
    // Notification levels
    if ([[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityNotificationLevels] && !room.isMyNotes) {
        UIAlertAction *notificationsAction = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Notifications: %@", room.notificationLevelString]
                                                                      style:UIAlertActionStyleDefault
                                                                    handler:^void (UIAlertAction *action) {
                                                                        [self setNotificationLevelForRoomAtIndexPath:indexPath];
                                                                    }];
        [notificationsAction setValue:[[UIImage imageNamed:@"notifications-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
        [optionsActionSheet addAction:notificationsAction];
    }
    // Share link
    if (room.isPublic) {
        // Share Link
        UIAlertAction *shareLinkAction = [UIAlertAction actionWithTitle:@"Share conversation link"
                                                                  style:UIAlertActionStyleDefault
                                                                handler:^void (UIAlertAction *action) {
                                                                    [self shareLinkFromRoomAtIndexPath:indexPath];
                                                                }];
        [shareLinkAction setValue:[[UIImage imageNamed:@"share-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
        [optionsActionSheet addAction:shareLinkAction];
    }
    // Room info
    UIAlertAction *roomInfoAction = [UIAlertAction actionWithTitle:@"Conversation info"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^void (UIAlertAction *action) {
                                                               [self presentRoomInfoForRoomAtIndexPath:indexPath];
                                                           }];
    [roomInfoAction setValue:[[UIImage imageNamed:@"room-info-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forKey:@"image"];
    [optionsActionSheet addAction:roomInfoAction];
    
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    optionsActionSheet.popoverPresentationController.sourceView = self.tableView;
    optionsActionSheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

- (void)presentChatForRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    [[NCRoomsManager sharedInstance] startChatInRoom:room];
}

#pragma mark - Utils

- (NSString *)getDateLabelStringForDate:(NSDate *)date
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    if ([date isToday]) {
        [formatter setDateFormat:@"HH:mm"];
    } else if ([date isYesterday]) {
        return @"Yesterday";
    } else {
        [formatter setDateFormat:@"dd/MM/yy"];
    }
    return [formatter stringFromDate:date];
}

- (void)showLeaveRoomLastModeratorErrorForRoom:(NCRoom *)room
{
    UIAlertController *leaveRoomFailedDialog =
    [UIAlertController alertControllerWithTitle:@"Could not leave conversation"
                                        message:[NSString stringWithFormat:@"You need to promote a new moderator before you can leave %@.", room.displayName]
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [leaveRoomFailedDialog addAction:okAction];
    
    [self presentViewController:leaveRoomFailedDialog animated:YES completion:nil];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _rooms.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return kRoomTableCellHeight;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleDelete;
}

- (NSString *)tableView:(UITableView *)tableView titleForSwipeAccessoryButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return @"More";
}

- (void)tableView:(UITableView *)tableView swipeAccessoryButtonPushedForRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self presentMoreActionsForRoomAtIndexPath:indexPath];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    NSString *deleteButtonText = @"Delete";
    if (room.isLeavable) {
        deleteButtonText = @"Leave";
    }
    return deleteButtonText;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NCRoom *room = [_rooms objectAtIndex:indexPath.row];
        if (_searchController.active) {
            room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
        }
        
        if (room.isLeavable) {
            [self leaveRoomAtIndexPath:indexPath];
        } else {
            [self deleteRoomAtIndexPath:indexPath];
        }
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
API_AVAILABLE(ios(11.0)){
    UIContextualAction *moreAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil
                                                                            handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
                                                                                [self presentMoreActionsForRoomAtIndexPath:indexPath];
                                                                                completionHandler(false);
                                                                            }];
    moreAction.image = [UIImage imageNamed:@"more-action"];
    
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil
                                                                            handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
                                                                                [self deleteRoomAtIndexPath:indexPath];
                                                                                completionHandler(false);
                                                                            }];
    deleteAction.image = [UIImage imageNamed:@"delete"];
    
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    
    if (room.isLeavable) {
        deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil
                                                             handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
                                                                 [self leaveRoomAtIndexPath:indexPath];
                                                                 completionHandler(false);
                                                             }];
        deleteAction.image = [UIImage imageNamed:@"exit-white"];
    }
    
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, moreAction]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(nonnull NSIndexPath *)indexPath
API_AVAILABLE(ios(11.0)){
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    if (_searchController.active) {
        room = [_resultTableViewController.rooms objectAtIndex:indexPath.row];
    }
    UIContextualAction *favoriteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil
                                                                               handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
                                                                                   if (room.isFavorite) {
                                                                                       [self removeRoomFromFavoritesAtIndexPath:indexPath];
                                                                                   } else {
                                                                                       [self addRoomToFavoritesAtIndexPath:indexPath];
                                                                                   }
                                                                                   completionHandler(true);
                                                                               }];
    favoriteAction.image = [UIImage imageNamed:@"fav-white"];
    favoriteAction.backgroundColor = [UIColor colorWithRed:0.97 green:0.80 blue:0.27 alpha:1.0]; // Favorite yellow
    
    return [UISwipeActionsConfiguration configurationWithActions:@[favoriteAction]];
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    RoomTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRoomCellIdentifier];
    if (!cell) {
        cell = [[RoomTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kRoomCellIdentifier];
    }
    
    // Set room name
    cell.titleLabel.text = room.displayName;
    
    // Set last activity
    if (room.lastMessage) {
        cell.titleOnly = NO;
        cell.subtitleLabel.text = room.lastMessageString;
    } else {
        cell.titleOnly = YES;
    }
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSince1970:room.lastActivity];
    cell.dateLabel.text = [self getDateLabelStringForDate:date];
    
    // Set unread messages
    BOOL mentioned = room.unreadMention || room.type == kNCRoomTypeOneToOne;
    [cell setUnreadMessages:room.unreadMessages mentioned:mentioned];
    
    // Set room image
    switch (room.type) {
        case kNCRoomTypeOneToOne:
            [cell.roomImage setImageWithURLRequest:[[NCAPIController sharedInstance] createAvatarRequestForUser:room.name andSize:96 usingAccount:[[NCDatabaseManager sharedInstance] activeAccount]]
                                  placeholderImage:nil success:nil failure:nil];
            break;
            
        case kNCRoomTypeGroup:
            [cell.roomImage setImage:[UIImage imageNamed:@"group-bg"]];
            break;
            
        case kNCRoomTypePublic:
            [cell.roomImage setImage:(room.hasPassword) ? [UIImage imageNamed:@"public-password-bg"] : [UIImage imageNamed:@"public-bg"]];
            break;
            
        case kNCRoomTypeChangelog:
            [cell.roomImage setImage:[UIImage imageNamed:@"changelog"]];
            break;
            
        case kNCRoomTypeNotes:
            [cell.roomImage setImage:[UIImage imageNamed:@"notes"]];
            break;
            
        default:
            break;
    }
    
    // Set objectType image
    if ([room.objectType isEqualToString:NCRoomObjectTypeFile]) {
        [cell.roomImage setImage:[UIImage imageNamed:@"file-bg"]];
    } else if ([room.objectType isEqualToString:NCRoomObjectTypeSharePassword]) {
        [cell.roomImage setImage:[UIImage imageNamed:@"password-bg"]];
    }
    
    // Set favorite image
    if (room.isFavorite) {
        [cell.favoriteImage setImage:[UIImage imageNamed:@"favorite-room"]];
    }
        
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self presentChatForRoomAtIndexPath:indexPath];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}


@end
