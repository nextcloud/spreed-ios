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

#import "NCAPIController.h"

#import "CCCertificate.h"
#import "NCAPISessionManager.h"
#import "NCAppBranding.h"
#import "NCConnectionController.h"
#import "NCDatabaseManager.h"
#import "NCImageSessionManager.h"
#import "NCPushProxySessionManager.h"
#import "NCSettingsController.h"
#import "NCUserInterfaceController.h"

NSString * const kNCOCSAPIVersion           = @"/ocs/v2.php";
NSString * const kNCSpreedAPIVersion        = @"/apps/spreed/api/v1";

NSInteger const kReceivedChatMessagesLimit = 100;

@interface NCAPIController () <NSURLSessionTaskDelegate, NSURLSessionDelegate, NCCommunicationCommonDelegate>

@property (nonatomic, strong) NCAPISessionManager *defaultAPISessionManager;

@end

@implementation NCAPIController

+ (NCAPIController *)sharedInstance
{
    static dispatch_once_t once;
    static NCAPIController *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        [self initSessionManagers];
        [self initImageDownloaders];
    }
    
    return self;
}

- (void)initSessionManagers
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.HTTPCookieStorage = nil;
    _defaultAPISessionManager = [[NCAPISessionManager alloc] initWithSessionConfiguration:configuration];
    
    _apiSessionManagers = [NSMutableDictionary new];
    
    for (TalkAccount *talkAccount in [TalkAccount allObjects]) {
        TalkAccount *account = [[TalkAccount alloc] initWithValue:talkAccount];
        [self createAPISessionManagerForAccount:account];
    }
}

- (void)createAPISessionManagerForAccount:(TalkAccount *)account
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedCookieStorageForGroupContainerIdentifier:account.accountId];
    configuration.HTTPCookieStorage = cookieStorage;
    NCAPISessionManager *apiSessionManager = [[NCAPISessionManager alloc] initWithSessionConfiguration:configuration];
    [apiSessionManager.requestSerializer setValue:[self authHeaderForAccount:account] forHTTPHeaderField:@"Authorization"];
    [_apiSessionManagers setObject:apiSessionManager forKey:account.accountId];
}

- (void)setupNCCommunicationForAccount:(TalkAccount *)account
{
    ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:account.accountId];
    NSString *userToken = [[NCSettingsController sharedInstance] tokenForAccountId:account.accountId];
    NSString *userAgent = [NSString stringWithFormat:@"Mozilla/5.0 (iOS) Nextcloud-Talk v%@", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"]];
    [[NCCommunicationCommon shared] setupWithAccount:account.accountId user:account.user userId:account.userId password:userToken
                                             urlBase:account.server userAgent:userAgent webDav:serverCapabilities.webDAVRoot dav:nil
                                    nextcloudVersion:serverCapabilities.versionMajor delegate:self];
}

- (void)initImageDownloaders
{
    _imageDownloader = [[AFImageDownloader alloc]
                        initWithSessionManager:[NCImageSessionManager sharedInstance]
                        downloadPrioritization:AFImageDownloadPrioritizationFIFO
                        maximumActiveDownloads:4
                                    imageCache:[[AFAutoPurgingImageCache alloc] init]];
    
    _imageDownloaderNoCache = [[AFImageDownloader alloc]
                               initWithSessionManager:[NCImageSessionManager sharedInstance]
                               downloadPrioritization:AFImageDownloadPrioritizationFIFO
                               maximumActiveDownloads:4
                                            imageCache:nil];
}

- (NSString *)authHeaderForAccount:(TalkAccount *)account
{
    NSString *userTokenString = [NSString stringWithFormat:@"%@:%@", account.user, [[NCSettingsController sharedInstance] tokenForAccountId:account.accountId]];
    NSData *data = [userTokenString dataUsingEncoding:NSUTF8StringEncoding];
    NSString *base64Encoded = [data base64EncodedStringWithOptions:0];
    
    return [[NSString alloc]initWithFormat:@"Basic %@",base64Encoded];
}

- (NSString *)conversationAPIVersionForAccount:(TalkAccount *)account
{
    NSString *conversationAPIVersion = @"/apps/spreed/api/v1";
    if ([[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityChatReadStatus forAccountId:account.accountId]) {
        conversationAPIVersion = @"/apps/spreed/api/v3";
    }
    
    return conversationAPIVersion;
}

- (NSString *)getRequestURLForAccount:(TalkAccount *)account withEndpoint:(NSString *)endpoint
{
    return [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, kNCSpreedAPIVersion, endpoint];
}

#pragma mark - Contacts Controller

- (NSURLSessionDataTask *)searchContactsForAccount:(TalkAccount *)account withPhoneNumbers:(NSDictionary *)phoneNumbers andCompletionBlock:(GetContactsWithPhoneNumbersCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/cloud/users/search/by-phone", account.server];
    NSString *location = [[NSLocale currentLocale] countryCode];
    NSDictionary *parameters = @{@"location" : location,
                                 @"search" : phoneNumbers};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *responseContacts = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(responseContacts, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        // NSInteger statusCode = [self getResponseStatusCode:task.response];
        // Ignore status code for now https://github.com/nextcloud/server/pull/26679
        // [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)getContactsForAccount:(TalkAccount *)account forRoom:(NSString *)room groupRoom:(BOOL)groupRoom withSearchParam:(NSString *)search andCompletionBlock:(GetContactsCompletionBlock)block
{
    NSMutableArray *shareTypes = [[NSMutableArray alloc] initWithObjects:@(NCShareTypeUser), nil];
    if (groupRoom && [[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityInviteGroupsAndMails]) {
        [shareTypes addObject:@(NCShareTypeGroup)];
        [shareTypes addObject:@(NCShareTypeEmail)];
        if ([[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityCirclesSupport]) {
            [shareTypes addObject:@(NCShareTypeCircle)];
        }
    }
    
    NSString *URLString = [NSString stringWithFormat:@"%@%@/core/autocomplete/get", account.server, kNCOCSAPIVersion];
    NSDictionary *parameters = @{@"format" : @"json",
                                 @"search" : search ? search : @"",
                                 @"limit" : @"50",
                                 @"itemType" : @"call",
                                 @"itemId" : room ? room : @"new",
                                 @"shareTypes" : shareTypes
                                 };
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSArray *responseContacts = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        NSMutableArray *users = [[NSMutableArray alloc] initWithCapacity:responseContacts.count];
        for (NSDictionary *user in responseContacts) {
            NCUser *ncUser = [NCUser userWithDictionary:user];
            TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
            if (ncUser && !([ncUser.userId isEqualToString:activeAccount.userId] && [ncUser.source isEqualToString:kParticipantTypeUser])) {
                [users addObject:ncUser];
            }
        }
        NSMutableDictionary *indexedContacts = [NCUser indexedUsersFromUsersArray:users];
        NSArray *indexes = [[indexedContacts allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        if (block) {
            block(indexes, indexedContacts, users, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, nil, nil, error);
        }
    }];
    
    return task;
}

#pragma mark - Rooms Controller

- (NSURLSessionDataTask *)getRoomsForAccount:(TalkAccount *)account updateStatus:(BOOL)updateStatus withCompletionBlock:(GetRoomsCompletionBlock)block
{
    NSString *endpoint = @"room";
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    NSDictionary *parameters = @{@"noStatusUpdate" : @(!updateStatus)};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nonnull responseObject) {
        NSArray *responseRooms = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(responseRooms, nil, 0);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error, statusCode);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)getRoomForAccount:(TalkAccount *)account withToken:(NSString *)token withCompletionBlock:(GetRoomCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *roomDict = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(roomDict, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)createRoomForAccount:(TalkAccount *)account with:(NSString *)invite ofType:(NCRoomType)type andName:(NSString *)roomName withCompletionBlock:(CreateRoomCompletionBlock)block
{
    NSString *endpoint = @"room";
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    NSMutableDictionary *parameters = [NSMutableDictionary new];
    
    [parameters setObject:@(type) forKey:@"roomType"];
    
    if (invite) {
        [parameters setObject:invite forKey:@"invite"];
    }
    
    if (roomName) {
        [parameters setObject:roomName forKey:@"roomName"];
    }
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSString *token = [[[responseObject objectForKey:@"ocs"] objectForKey:@"data"] objectForKey:@"token"];
        if (block) {
            block(token, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)renameRoom:(NSString *)token forAccount:(TalkAccount *)account withName:(NSString *)newName andCompletionBlock:(RenameRoomCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    NSDictionary *parameters = @{@"roomName" : newName};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager PUT:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)makeRoomPublic:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(MakeRoomPublicCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/public", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)makeRoomPrivate:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(MakeRoomPrivateCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/public", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)deleteRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(DeleteRoomCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)setPassword:(NSString *)password toRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(SetPasswordCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/password", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    NSDictionary *parameters = @{@"password" : password};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager PUT:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)joinRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(JoinRoomCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/participants/active", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSString *sessionId = [[[responseObject objectForKey:@"ocs"] objectForKey:@"data"] objectForKey:@"sessionId"];
        if (block) {
            block(sessionId, nil, 0);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error, statusCode);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)exitRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(ExitRoomCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/participants/active", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)addRoomToFavorites:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(FavoriteRoomCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/favorite", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)removeRoomFromFavorites:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(FavoriteRoomCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/favorite", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)setNotificationLevel:(NCRoomNotificationLevel)level forRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(NotificationLevelCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/notify", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    NSDictionary *parameters = @{@"level" : @(level)};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)setReadOnlyState:(NCRoomReadOnlyState)state forRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(ReadOnlyCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/read-only", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    NSDictionary *parameters = @{@"state" : @(state)};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager PUT:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)setLobbyState:(NCRoomLobbyState)state withTimer:(NSInteger)timer forRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(SetLobbyStateCompletionBlock)block
{
    NSString *encodedToken = [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *endpoint = [NSString stringWithFormat:@"room/%@/webinary/lobby", encodedToken];
    NSString *conversationAPIVersion = [self conversationAPIVersionForAccount:account];
    NSString *URLString = [NSString stringWithFormat:@"%@%@%@/%@", account.server, kNCOCSAPIVersion, conversationAPIVersion, endpoint];
    NSMutableDictionary *parameters = [NSMutableDictionary new];
    [parameters setObject:@(state) forKey:@"state"];
    if (timer > 0) {
        [parameters setObject:@(timer) forKey:@"timer"];
    }
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager PUT:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

#pragma mark - Participants Controller

- (NSURLSessionDataTask *)getParticipantsFromRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(GetParticipantsFromRoomCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"room/%@/participants", token]];
    ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:account.accountId];
    if (serverCapabilities.userStatus) {
        URLString = [URLString stringByAppendingString:@"?includeStatus=true"];
    }
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSArray *responseParticipants = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        NSMutableArray *participants = [[NSMutableArray alloc] initWithCapacity:responseParticipants.count];
        for (NSDictionary *participantDict in responseParticipants) {
            NCRoomParticipant *participant = [NCRoomParticipant participantWithDictionary:participantDict];
            [participants addObject:participant];
        }
        
        // Sort participants by:
        // - Moderators first
        // - Online status
        // - Users > Guests
        // - Alphabetic
        NSSortDescriptor *alphabeticSorting = [[NSSortDescriptor alloc] initWithKey:@"displayName" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
        NSSortDescriptor *customSorting = [NSSortDescriptor sortDescriptorWithKey:@"" ascending:YES comparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
            NCRoomParticipant *first = (NCRoomParticipant*)obj1;
            NCRoomParticipant *second = (NCRoomParticipant*)obj2;
            
            BOOL moderator1 = first.canModerate;
            BOOL moderator2 = second.canModerate;
            if (moderator1 != moderator2) {
                return moderator2 - moderator1;
            }
            
            BOOL online1 = !first.isOffline;
            BOOL online2 = !second.isOffline;
            if (online1 != online2) {
                return online2 - online1;
            }
            
            BOOL guest1 = first.participantType == kNCParticipantTypeGuest;
            BOOL guest2 = second.participantType == kNCParticipantTypeGuest;
            if (guest1 != guest2) {
                return guest1 - guest2;
            }
            
            return NSOrderedSame;
        }];
        NSArray *descriptors = [NSArray arrayWithObjects:customSorting, alphabeticSorting, nil];
        [participants sortUsingDescriptors:descriptors];
        
        if (block) {
            block(participants, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)addParticipant:(NSString *)participant ofType:(NSString *)type toRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(ParticipantModificationCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"room/%@/participants", token]];
    NSMutableDictionary *parameters = [NSMutableDictionary new];
    [parameters setObject:participant forKey:@"newParticipant"];
    if (type && ![type isEqualToString:@""]) {
        [parameters setObject:type forKey:@"source"];
    }
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)removeParticipant:(NSString *)user fromRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(ParticipantModificationCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"room/%@/participants", token]];
    NSDictionary *parameters = @{@"participant" : user};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)removeGuest:(NSString *)guest fromRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(ParticipantModificationCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"room/%@/participants/guests", token]];
    NSDictionary *parameters = @{@"participant" : guest};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)removeSelfFromRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(LeaveRoomCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"room/%@/participants/self", token]];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(0, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(statusCode, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)promoteParticipant:(NSString *)user toModeratorOfRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(ParticipantModificationCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"room/%@/moderators", token]];
    NSDictionary *parameters = @{@"participant" : user};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)demoteModerator:(NSString *)moderator toParticipantOfRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(ParticipantModificationCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"room/%@/moderators", token]];
    NSDictionary *parameters = @{@"participant" : moderator};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

#pragma mark - Call Controller

- (NSURLSessionDataTask *)getPeersForCall:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(GetPeersForCallCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"call/%@", token]];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSArray *responsePeers = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        NSMutableArray *peers = [[NSMutableArray alloc] initWithArray:responsePeers];
        if (block) {
            block(peers, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)joinCall:(NSString *)token withCallFlags:(NSInteger)flags forAccount:(TalkAccount *)account withCompletionBlock:(JoinCallCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"call/%@", token]];
    NSDictionary *parameters = @{@"flags" : @(flags)};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil, 0);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error, statusCode);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)leaveCall:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(LeaveCallCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"call/%@", token]];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

#pragma mark - Chat Controller

- (NSURLSessionDataTask *)receiveChatMessagesOfRoom:(NSString *)token fromLastMessageId:(NSInteger)messageId history:(BOOL)history includeLastMessage:(BOOL)include timeout:(BOOL)timeout lastCommonReadMessage:(NSInteger)lastCommonReadMessage forAccount:(TalkAccount *)account withCompletionBlock:(GetChatMessagesCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"chat/%@", token]];
    NSDictionary *parameters = @{@"lookIntoFuture" : history ? @(0) : @(1),
                                 @"limit" : @(kReceivedChatMessagesLimit),
                                 @"timeout" : timeout ? @(30) : @(0),
                                 @"lastKnownMessageId" : @(messageId),
                                 @"lastCommonReadId" : @(lastCommonReadMessage),
                                 @"setReadMarker" : @(1),
                                 @"includeLastKnown" : include ? @(1) : @(0)};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSArray *responseMessages = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        // Get X-Chat-Last-Given and X-Chat-Last-Common-Read headers
        NSHTTPURLResponse *response = ((NSHTTPURLResponse *)[task response]);
        NSDictionary *headers = [response allHeaderFields];
        NSString *lastKnowMessageHeader = [headers objectForKey:@"X-Chat-Last-Given"];
        NSInteger lastKnownMessage = -1;
        if (lastKnowMessageHeader) {
            lastKnownMessage = [lastKnowMessageHeader integerValue];
        }
        NSString *lastCommonReadMessageHeader = [headers objectForKey:@"X-Chat-Last-Common-Read"];
        NSInteger lastCommonReadMessage = -1;
        if (lastCommonReadMessageHeader) {
            lastCommonReadMessage = [lastCommonReadMessageHeader integerValue];
        }
        
        if (block) {
            block(responseMessages, lastKnownMessage, lastCommonReadMessage, nil, 0);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, -1, -1, error, statusCode);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)sendChatMessage:(NSString *)message toRoom:(NSString *)token displayName:(NSString *)displayName replyTo:(NSInteger)replyTo referenceId:(NSString *)referenceId forAccount:(TalkAccount *)account withCompletionBlock:(SendChatMessagesCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"chat/%@", token]];
    NSMutableDictionary *parameters = [NSMutableDictionary new];
    [parameters setObject:message forKey:@"message"];
    if (replyTo > -1) {
        [parameters setObject:@(replyTo) forKey:@"replyTo"];
    }
    if (referenceId) {
        [parameters setObject:referenceId forKey:@"referenceId"];
    }
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    // Work around: When sendChatMessage is called from Share Extension session managers are not initialized.
    if (!apiSessionManager) {
        [self initSessionManagers];
        apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    }
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)getMentionSuggestionsInRoom:(NSString *)token forString:(NSString *)string forAccount:(TalkAccount *)account withCompletionBlock:(GetMentionSuggestionsCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"chat/%@/mentions", token]];
    ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:account.accountId];
    NSDictionary *parameters = @{@"limit" : @"20",
                                 @"search" : string ? string : @"",
                                 @"includeStatus" : @(serverCapabilities.userStatus)
    };
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSArray *mentions = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        NSMutableArray *suggestions = [[NSMutableArray alloc] initWithArray:mentions];;
        if (block) {
            block(suggestions, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)deleteChatMessageInRoom:(NSString *)token withMessageId:(NSInteger)messageId forAccount:(TalkAccount *)account withCompletionBlock:(DeleteChatMessageCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"chat/%@/%ld", token, (long)messageId]];
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *messageDict = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
            block(messageDict, nil, httpResponse.statusCode);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error, statusCode);
        }
    }];
    
    return task;
}

#pragma mark - Signaling Controller

- (NSURLSessionDataTask *)sendSignalingMessages:(NSString *)messages toRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(SendSignalingMessagesCompletionBlock)block;
{
    NSString *endpoint = (token) ? [NSString stringWithFormat:@"signaling/%@", token] : @"signaling";
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:endpoint];
    NSDictionary *parameters = @{@"messages" : messages};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)pullSignalingMessagesFromRoom:(NSString *)token forAccount:(TalkAccount *)account withCompletionBlock:(PullSignalingMessagesCompletionBlock)block
{
    NSString *endpoint = (token) ? [NSString stringWithFormat:@"signaling/%@", token] : @"signaling";
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:endpoint];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString
                                             parameters:nil progress:nil
                                                success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *responseDict = responseObject;
        if (block) {
            block(responseDict, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)getSignalingSettingsForAccount:(TalkAccount *)account withCompletionBlock:(GetSignalingSettingsCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:@"signaling/settings"];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *responseDict = responseObject;
        if (block) {
            block(responseDict, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSString *)authenticationBackendUrlForAccount:(TalkAccount *)account
{
    return [self getRequestURLForAccount:account withEndpoint:@"signaling/backend"];
}

#pragma mark - Settings

- (NSURLSessionDataTask *)setReadStatusPrivacySettingEnabled:(BOOL)enabled forAccount:(TalkAccount *)account withCompletionBlock:(SetReadStatusPrivacySettingCompletionBlock)block
{
    NSString *URLString = [self getRequestURLForAccount:account withEndpoint:[NSString stringWithFormat:@"settings/user"]];
    NSDictionary *parameters = @{@"key" : @"read_status_privacy",
                                 @"value" : @(enabled)};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

#pragma mark - Files

- (void)readFolderForAccount:(TalkAccount *)account atPath:(NSString *)path depth:(NSString *)depth withCompletionBlock:(ReadFolderCompletionBlock)block
{
    [self setupNCCommunicationForAccount:account];
    ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:account.accountId];
    NSString *serverUrlString = [NSString stringWithFormat:@"%@/%@/%@", account.server, serverCapabilities.webDAVRoot, path ? path : @""];
    [[NCCommunication shared] readFileOrFolderWithServerUrlFileName:serverUrlString depth:depth showHiddenFiles:NO requestBody:nil customUserAgent:nil addCustomHeaders:nil completionHandler:^(NSString *accounts, NSArray<NCCommunicationFile *> *files, NSData *responseData, NSInteger errorCode, NSString *errorDescription) {
        if (errorCode == 0 && block) {
            block(files, nil);
        } else if (block) {
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:errorCode userInfo:nil];
            block(nil, error);
        }
    }];
}

- (void)shareFileOrFolderForAccount:(TalkAccount *)account atPath:(NSString *)path toRoom:(NSString *)token withCompletionBlock:(ShareFileOrFolderCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/files_sharing/api/v1/shares", account.server];
    NSDictionary *parameters = @{@"path" : path,
                                 @"shareType" : @(10),
                                 @"shareWith" : token
                                 };
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    // Work around: When sendChatMessage is called from Share Extension session managers are not initialized.
    if (!apiSessionManager) {
        [self initSessionManagers];
        apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    }
    [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
        // Do not return error when re-sharing a file or folder.
        if (httpResponse.statusCode == 403 && block) {
            block(nil);
        } else if (block) {
            block(error);
        }
    }];
}

- (void)getFileByFileId:(TalkAccount *)account fileId:(NSString *)fileId withCompletionBlock:(GetFileByFileIdCompletionBlock)block
{
    [self setupNCCommunicationForAccount:account];
    
    NSString *body = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
    <d:searchrequest xmlns:d=\"DAV:\" xmlns:oc=\"http://nextcloud.com/ns\">\
        <d:basicsearch>\
            <d:select>\
                <d:prop>\
                    <d:displayname />\
                    <d:getcontenttype />\
                    <d:resourcetype />\
                    <d:getcontentlength />\
                    <d:getlastmodified />\
                    <d:creationdate />\
                    <d:getetag />\
                    <d:quota-used-bytes />\
                    <d:quota-available-bytes />\
                    <oc:permissions xmlns:oc=\"http://owncloud.org/ns\" />\
                    <oc:id xmlns:oc=\"http://owncloud.org/ns\" />\
                    <oc:size xmlns:oc=\"http://owncloud.org/ns\" />\
                    <oc:favorite xmlns:oc=\"http://owncloud.org/ns\" />\
                </d:prop>\
            </d:select>\
            <d:from>\
                <d:scope>\
                    <d:href>/files/%@</d:href>\
                    <d:depth>infinity</d:depth>\
                </d:scope>\
            </d:from>\
            <d:where>\
                <d:eq>\
                    <d:prop>\
                        <oc:fileid xmlns:oc=\"http://owncloud.org/ns\" />\
                    </d:prop>\
                    <d:literal>%@</d:literal>\
                </d:eq>\
            </d:where>\
            <d:orderby />\
        </d:basicsearch>\
    </d:searchrequest>";
    
    NSString *bodyRequest = [NSString stringWithFormat:body, account.userId, fileId];
    [[NCCommunication shared] searchBodyRequestWithServerUrl:account.server requestBody:bodyRequest showHiddenFiles:YES customUserAgent:nil addCustomHeaders:nil timeout:0 completionHandler:^(NSString *account, NSArray<NCCommunicationFile *> *files, NSInteger error, NSString *errorDescription) {
        
        if (block) {
            if ([files count] > 0) {
                block([files objectAtIndex:0], error, errorDescription);
            } else {
                block(nil, error, errorDescription);
            }
        }
    }];
}

#pragma mark - User avatars

- (NSURLRequest *)createAvatarRequestForUser:(NSString *)userId andSize:(NSInteger)size usingAccount:(TalkAccount *)account
{
    return [self createAvatarRequestForUser:userId withCachePolicy:NSURLRequestReturnCacheDataElseLoad andSize:size usingAccount:account];
}

- (NSURLRequest *)createAvatarRequestForUser:(NSString *)userId withCachePolicy:(NSURLRequestCachePolicy)cachePolicy andSize:(NSInteger)size usingAccount:(TalkAccount *)account
{
    NSString *encodedUser = [userId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"%@/index.php/avatar/%@/%ld", account.server, encodedUser, (long)size];
    NSMutableURLRequest *avatarRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:cachePolicy timeoutInterval:60];
    [avatarRequest setValue:[self authHeaderForAccount:account] forHTTPHeaderField:@"Authorization"];
    return avatarRequest;
}

- (void)getUserAvatarForUser:(NSString *)userId andSize:(NSInteger)size usingAccount:(TalkAccount *)account withCompletionBlock:(GetUserAvatarImageForUserCompletionBlock)block
{
    NSURLRequest *request = [self createAvatarRequestForUser:userId andSize:size usingAccount:account];
    [_imageDownloader downloadImageForURLRequest:request success:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, UIImage * _Nonnull responseObject) {
        NSData *pngData = UIImagePNGRepresentation(responseObject);
        UIImage *image = [UIImage imageWithData:pngData];
        
        if (image && block) {
            block(image, nil);
        }
    } failure:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, NSError * _Nonnull error) {
        if (block) {
            block(nil, error);
        }
    }];
}

#pragma mark - File previews

- (NSURLRequest *)createPreviewRequestForFile:(NSString *)fileId width:(NSInteger)width height:(NSInteger)height usingAccount:(TalkAccount *)account
{
    NSString *urlString = [NSString stringWithFormat:@"%@/index.php/core/preview?fileId=%@&x=%ld&y=%ld&forceIcon=1", account.server, fileId, (long)width, (long)height];
    NSMutableURLRequest *previewRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:60];
    [previewRequest setValue:[self authHeaderForAccount:account] forHTTPHeaderField:@"Authorization"];
    return previewRequest;
}

#pragma mark - User profile

- (NSURLSessionDataTask *)getUserProfileForAccount:(TalkAccount *)account withCompletionBlock:(GetUserProfileCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/cloud/user", account.server];
    NSDictionary *parameters = @{@"format" : @"json"};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *profile = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(profile, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)getUserProfileEditableFieldsForAccount:(TalkAccount *)account withCompletionBlock:(GetUserProfileEditableFieldsCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/cloud/user/fields", account.server];
    NSDictionary *parameters = @{@"format" : @"json"};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSArray *editableFields = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(editableFields, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)setUserProfileField:(NSString *)field withValue:(NSString*)value forAccount:(TalkAccount *)account withCompletionBlock:(SetUserProfileFieldCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/cloud/users/%@", account.server, account.userId];
    NSDictionary *parameters = @{@"format" : @"json",
                                 @"key" : field,
                                 @"value" : value};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager PUT:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil, 0);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        // Ignore status code for now https://github.com/nextcloud/server/pull/26679
        // [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error, statusCode);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)setUserProfileImage:(UIImage *)image forAccount:(TalkAccount *)account withCompletionBlock:(SetUserProfileFieldCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/spreed/temp-user-avatar", account.server];
    NSData *imageData= UIImageJPEGRepresentation(image, 0.7);
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:nil constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        [formData appendPartWithFileData:imageData name:@"files[]" fileName:@"avatar.jpg" mimeType:@"image/jpeg"];
    } progress:nil success:^(NSURLSessionDataTask *task, id responseObject) {
        if (block) {
            block(nil, 0);
        }
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error, statusCode);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)removeUserProfileImageForAccount:(TalkAccount *)account withCompletionBlock:(SetUserProfileFieldCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/spreed/temp-user-avatar", account.server];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil, 0);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error, statusCode);
        }
    }];
    
    return task;
}

- (void)saveProfileImageForAccount:(TalkAccount *)account
{
    NSURLRequest *request = [self createAvatarRequestForUser:account.userId withCachePolicy:NSURLRequestReloadIgnoringCacheData andSize:160 usingAccount:account];
    [_imageDownloader downloadImageForURLRequest:request success:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, UIImage * _Nonnull responseObject) {
        
        NSDictionary *headers = [response allHeaderFields];
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm beginWriteTransaction];
        NSPredicate *query = [NSPredicate predicateWithFormat:@"accountId = %@", account.accountId];
        TalkAccount *managedAccount = [TalkAccount objectsWithPredicate:query].firstObject;
        managedAccount.hasCustomAvatar = [[headers objectForKey:@"X-NC-IsCustomAvatar"] boolValue];
        [realm commitWriteTransaction];
        
        NSData *pngData = UIImagePNGRepresentation(responseObject);
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths objectAtIndex:0];
        NSString *fileName = [NSString stringWithFormat:@"%@-%@.png", account.userId, [[NSURL URLWithString:account.server] host]];
        NSString *filePath = [documentsPath stringByAppendingPathComponent:fileName];
        [pngData writeToFile:filePath atomically:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:NCUserProfileImageUpdatedNotification object:self userInfo:nil];
    } failure:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, NSError * _Nonnull error) {
        NSLog(@"Could not download user profile image");
    }];
}

- (UIImage *)userProfileImageForAccount:(TalkAccount *)account withSize:(CGSize)size
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = [paths objectAtIndex:0];
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.png", account.userId, [[NSURL URLWithString:account.server] host]];
    NSString *filePath = [documentsPath stringByAppendingPathComponent:fileName];
    return [self imageWithImage:[UIImage imageWithContentsOfFile:filePath] convertToSize:size];
}

- (void)removeProfileImageForAccount:(TalkAccount *)account
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = [paths objectAtIndex:0];
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.png", account.userId, [[NSURL URLWithString:account.server] host]];
    NSString *filePath = [documentsPath stringByAppendingPathComponent:fileName];
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
}

- (UIImage *)imageWithImage:(UIImage *)image convertToSize:(CGSize)size
{
    if (image) {
        UIGraphicsBeginImageContext(size);
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
        UIImage *destImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return destImage;
    }
    
    return nil;
}

#pragma mark - User Status

- (NSURLSessionDataTask *)getUserStatusForAccount:(TalkAccount *)account withCompletionBlock:(GetUserStatusCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/user_status/api/v1/user_status", account.server];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *userStatus = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(userStatus, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)setUserStatus:(NSString *)status forAccount:(TalkAccount *)account withCompletionBlock:(SetUserStatusCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/user_status/api/v1/user_status/status", account.server];
    NSDictionary *parameters = @{@"statusType" : status};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager PUT:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

#pragma mark - Server capabilities

- (NSURLSessionDataTask *)getServerCapabilitiesForServer:(NSString *)server withCompletionBlock:(GetServerCapabilitiesCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v1.php/cloud/capabilities", server];
    NSDictionary *parameters = @{@"format" : @"json"};
    
    NSURLSessionDataTask *task = [_defaultAPISessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *capabilities = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(capabilities, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)getServerCapabilitiesForAccount:(TalkAccount *)account withCompletionBlock:(GetServerCapabilitiesCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v1.php/cloud/capabilities", account.server];
    NSDictionary *parameters = @{@"format" : @"json"};
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *capabilities = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(capabilities, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

#pragma mark - Server notifications

- (NSURLSessionDataTask *)getServerNotification:(NSInteger)notificationId forAccount:(TalkAccount *)account withCompletionBlock:(GetServerNotificationCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/notifications/api/v2/notifications/%ld", account.server, (long)notificationId];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager GET:URLString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *notification = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(notification, nil, 0);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error, statusCode);
        }
    }];
    
    return task;
}


#pragma mark - Push Notifications

- (NSURLSessionDataTask *)subscribeAccount:(TalkAccount *)account toNextcloudServerWithCompletionBlock:(SubscribeToNextcloudServerCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/notifications/api/v2/push", account.server];
    NSString *devicePublicKey = [[NSString alloc] initWithData:account.pushNotificationPublicKey encoding:NSUTF8StringEncoding];

    NSDictionary *parameters = @{@"pushTokenHash" : [[NCSettingsController sharedInstance] pushTokenSHA512],
                                 @"devicePublicKey" : devicePublicKey,
                                 @"proxyServer" : pushNotificationServer
                                 };
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *responseDict = [[responseObject objectForKey:@"ocs"] objectForKey:@"data"];
        if (block) {
            block(responseDict, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(nil, error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)unsubscribeAccount:(TalkAccount *)account fromNextcloudServerWithCompletionBlock:(UnsubscribeToNextcloudServerCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/ocs/v2.php/apps/notifications/api/v2/push", account.server];
    
    NCAPISessionManager *apiSessionManager = [_apiSessionManagers objectForKey:account.accountId];
    NSURLSessionDataTask *task = [apiSessionManager DELETE:URLString parameters:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSInteger statusCode = [self getResponseStatusCode:task.response];
        [self checkResponseStatusCode:statusCode forAccount:account];
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)subscribeAccount:(TalkAccount *)account toPushServerWithCompletionBlock:(SubscribeToPushProxyCompletionBlock)block
{
    NSString *URLString = [NSString stringWithFormat:@"%@/devices", pushNotificationServer];
    NSDictionary *parameters = @{@"pushToken" : [[NCSettingsController sharedInstance] combinedPushToken],
                                 @"deviceIdentifier" : account.deviceIdentifier,
                                 @"deviceIdentifierSignature" : account.deviceSignature,
                                 @"userPublicKey" : account.userPublicKey
                                 };

    NSURLSessionDataTask *task = [[NCPushProxySessionManager sharedInstance] POST:URLString parameters:parameters progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

- (NSURLSessionDataTask *)unsubscribeAccount:(TalkAccount *)account fromPushServerWithCompletionBlock:(UnsubscribeToPushProxyCompletionBlock)block
{    
    NSString *URLString = [NSString stringWithFormat:@"%@/devices", pushNotificationServer];
    NSDictionary *parameters = @{@"deviceIdentifier" : account.deviceIdentifier,
                                 @"deviceIdentifierSignature" : account.deviceSignature,
                                 @"userPublicKey" : account.userPublicKey
                                 };

    NSURLSessionDataTask *task = [[NCPushProxySessionManager sharedInstance] DELETE:URLString parameters:parameters success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if (block) {
            block(nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        if (block) {
            block(error);
        }
    }];
    
    return task;
}

#pragma mark - Error handling

- (NSInteger)getResponseStatusCode:(NSURLResponse *)response
{
    NSInteger statusCode = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        statusCode = httpResponse.statusCode;
    }
    return statusCode;
}

- (void)checkResponseStatusCode:(NSInteger)statusCode forAccount:(TalkAccount *)account
{
    // App token has been revoked
    if (statusCode == 401) {
        [[NCSettingsController sharedInstance] logoutAccountWithAccountId:account.accountId withCompletionBlock:^(NSError *error) {
            [[NCUserInterfaceController sharedInstance] presentConversationsList];
            [[NCUserInterfaceController sharedInstance] presentLoggedOutInvalidCredentialsAlert];
            [[NCConnectionController sharedInstance] checkAppState];
        }];
    }
}

#pragma mark - NCCommunicationCommon Delegate

- (void)authenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    // The pinnning check
    if ([[CCCertificate sharedManager] checkTrustedChallenge:challenge]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}


@end

#pragma mark - OCURLSessionManager

@implementation OCURLSessionManager

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    // The pinnning check
    if ([[CCCertificate sharedManager] checkTrustedChallenge:challenge]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

@end
