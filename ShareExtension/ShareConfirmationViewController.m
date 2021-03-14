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

#import "ShareConfirmationViewController.h"
#import "ShareConfirmationCollectionViewCell.h"

#import <AVFoundation/AVFoundation.h>
#import <NCCommunication/NCCommunication.h>
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <TOCropViewController/TOCropViewController.h>

#import "CCCertificate.h"
#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCSettingsController.h"
#import "NCUtils.h"
#import "MBProgressHUD.h"
#import "NCNavigationController.h"
#import "NCUserInterfaceController.h"
#import "NCIntentController.h"


@interface ShareConfirmationViewController () <NCCommunicationCommonDelegate, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, QLPreviewControllerDataSource, QLPreviewControllerDelegate, ShareItemControllerDelegate, TOCropViewControllerDelegate, UIImagePickerControllerDelegate, UIDocumentPickerDelegate, UINavigationControllerDelegate>
{
    UIBarButtonItem *_sendButton;
    UIActivityIndicatorView *_sharingIndicatorView;
    MBProgressHUD *_hud;
    dispatch_group_t _uploadGroup;
    BOOL _uploadFailed;
    NSMutableArray *_uploadErrors;
}

@property (nonatomic, strong) UIImagePickerController *imagePicker;

@end

@implementation ShareConfirmationViewController

- (id)initWithRoom:(NCRoom *)room account:(TalkAccount *)account serverCapabilities:(ServerCapabilities *)serverCapabilities
{
    self = [super init];
    if (self) {
        self.room = room;
        self.account = account;
        self.serverCapabilities = serverCapabilities;
    }
    
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.navigationController.navigationBar.translucent = NO;
    
    self.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
    self.navigationController.navigationBar.barTintColor = [NCAppBranding themeColor];
    self.tabBarController.tabBar.tintColor = [NCAppBranding themeColor];
    
    if (@available(iOS 13.0, *)) {
        UIColor *themeColor = [NCAppBranding themeColor];
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = themeColor;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
        self.navigationItem.standardAppearance = appearance;
        self.navigationItem.compactAppearance = appearance;
        self.navigationItem.scrollEdgeAppearance = appearance;
    }
    
    self.pageControl.currentPageIndicatorTintColor = [NCAppBranding elementColor];
    self.pageControl.pageIndicatorTintColor = [NCAppBranding placeholderColor];
    self.pageControl.hidesForSinglePage = YES;
    self.pageControl.numberOfPages = 1;
    
    if (_isModal) {
        UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                      target:self action:@selector(cancelButtonPressed)];
        cancelButton.accessibilityHint = NSLocalizedString(@"Double tap to dismiss sharing options", nil);
        self.navigationController.navigationBar.topItem.leftBarButtonItem = cancelButton;
    }
    
    _sendButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Send", nil) style:UIBarButtonItemStyleDone
                                                  target:self action:@selector(sendButtonPressed)];
    _sendButton.accessibilityHint = NSLocalizedString(@"Double tap to share with selected conversations", nil);
    self.navigationItem.rightBarButtonItem = _sendButton;
    
    _sharingIndicatorView = [[UIActivityIndicatorView alloc] init];
    _sharingIndicatorView.color = [NCAppBranding themeTextColor];
    
    // Configure communication lib
    NSString *userToken = [[NCSettingsController sharedInstance] tokenForAccountId:_account.accountId];
    NSString *userAgent = [NSString stringWithFormat:@"Mozilla/5.0 (iOS) Nextcloud-Talk v%@", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"]];
    
    [[NCCommunicationCommon shared] setupWithAccount:_account.accountId user:_account.user userId:_account.userId password:userToken
                                             urlBase:_account.server userAgent:userAgent webDav:_serverCapabilities.webDAVRoot dav:nil
                                    nextcloudVersion:_serverCapabilities.versionMajor delegate:self];
    
    // Set to section
    NSDictionary *attributes = @{NSFontAttributeName:[UIFont systemFontOfSize:15],
                                 NSForegroundColorAttributeName:[UIColor darkTextColor]};
    NSDictionary *subAttribute = @{NSFontAttributeName:[UIFont boldSystemFontOfSize:15],
                                   NSForegroundColorAttributeName:[UIColor lightGrayColor]};
    
    if (@available(iOS 13.0, *)) {
        attributes = @{NSFontAttributeName:[UIFont systemFontOfSize:15],
                       NSForegroundColorAttributeName:[UIColor labelColor]};
        subAttribute = @{NSFontAttributeName:[UIFont boldSystemFontOfSize:15],
                         NSForegroundColorAttributeName:[UIColor tertiaryLabelColor]};
    }
    
    NSString *localizedToString = NSLocalizedString(@"To:", @"TRANSLATORS this is for sending something 'to' a user. Eg. 'To: John Doe'");
    NSMutableAttributedString *toString = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ %@", localizedToString, _room.displayName] attributes:attributes];
    [toString addAttributes:subAttribute range:NSMakeRange(0, [localizedToString length])];
    self.toLabel.attributedText = toString;
    
    // Toolbar section
    [self.removeItemButton setEnabled:([self.shareItemController.shareItems count] > 1)];
    [self.removeItemButton setTintColor:([self.shareItemController.shareItems count] > 1) ? nil : [UIColor clearColor]];
        
    self.shareCollectionView.delegate = self;
    
    self.shareItemController = [[ShareItemController alloc] init];
    self.shareItemController.delegate = self;
    
    NSBundle *bundle = [NSBundle bundleForClass:[ShareConfirmationCollectionViewCell class]];
    [self.shareCollectionView registerNib:[UINib nibWithNibName:kShareConfirmationTableCellNibName bundle:bundle] forCellWithReuseIdentifier:kShareConfirmationCellIdentifier];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];
    
    _type = ShareConfirmationTypeItem;
}

- (void)viewDidAppear:(BOOL)animated
{
    if (_type == ShareConfirmationTypeText) {
        [self.itemToolbar setHidden:YES];
        [self.shareTextView becomeFirstResponder];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    if (_type == ShareConfirmationTypeText) {
        return;
    }
    
    // Hide the collection view
    [self.shareCollectionView setHidden:YES];
    // Invalidate layout to remove warning about item size must be less than UICollectionView
    [self.shareCollectionView.collectionViewLayout invalidateLayout];
    ShareItem *currentItem =  [self getCurrentShareItem];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // Invalidate the view now so cell size is correctly calculated
        // The size of the collection view is correct at this moment
        [self.shareCollectionView.collectionViewLayout invalidateLayout];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // Scroll to the element and make collection view appear
        [self scrollToItem:currentItem animated:NO];
        [self.shareCollectionView setHidden:NO];
    }];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Button Actions

- (void)cancelButtonPressed
{
    [self.delegate shareConfirmationViewControllerDidFinish:self];
}

- (void)sendButtonPressed
{
    if (_type == ShareConfirmationTypeText) {
        [self sendSharedText];
    } else {
        [self uploadAndShareFiles];
    }
    
    [self startAnimatingSharingIndicator];
}

- (IBAction)removeItemButtonPressed:(id)sender {
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [self.shareItemController removeItem:item];
    }
}

- (IBAction)cropItemButtonPressed:(id)sender {
    ShareItem *item = [self getCurrentShareItem];
    UIImage *image = [self.shareItemController getImageFromItem:item];
    
    if (!image) {
        return;
    }
    
    TOCropViewController *cropViewController = [[TOCropViewController alloc] initWithImage:image];
    cropViewController.delegate = self;
    [self presentViewController:cropViewController animated:YES completion:nil];
}

- (IBAction)previewItemButtonPressed:(id)sender {
    [self previewCurrentItem];
}

- (IBAction)addItemButtonPressed:(id)sender {
    [self presentAdditionalItemOptions];
}


- (void)shareText:(NSString *)sharedText
{
    _type = ShareConfirmationTypeText;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.shareCollectionView.hidden = YES;
        self.itemToolbar.hidden = YES;
        self.shareTextView.hidden = NO;
        self.shareTextView.text = sharedText;
    });
}

- (void)setIsModal:(BOOL)isModal
{
    _isModal = isModal;
}

#pragma mark - Add additional items
- (void)presentAdditionalItemOptions
{
    UIAlertController *optionsActionSheet = [UIAlertController alertControllerWithTitle:nil
                                                                                message:nil
                                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction *cameraAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Camera", nil)
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^void (UIAlertAction *action) {
        [self checkAndPresentCamera];
    }];
    [cameraAction setValue:[[UIImage imageNamed:@"camera"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];
    
    UIAlertAction *photoLibraryAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Photo Library", nil)
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^void (UIAlertAction *action) {
        [self presentPhotoLibrary];
    }];
    [photoLibraryAction setValue:[[UIImage imageNamed:@"photos"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];
    
    UIAlertAction *filesAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Files", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:^void (UIAlertAction *action) {
        [self presentDocumentPicker];
    }];
    [filesAction setValue:[[UIImage imageNamed:@"files"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];

#ifndef APP_EXTENSION
    // Camera access is not available in app extensions
    // https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html
    if ([UIImagePickerController isSourceTypeAvailable: UIImagePickerControllerSourceTypeCamera]) {
        [optionsActionSheet addAction:cameraAction];
    }
#endif
    
    [optionsActionSheet addAction:photoLibraryAction];
    [optionsActionSheet addAction:filesAction];
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    optionsActionSheet.popoverPresentationController.barButtonItem = self.addItemButton;
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

- (void)checkAndPresentCamera
{
    // https://stackoverflow.com/a/20464727/2512312
    NSString *mediaType = AVMediaTypeVideo;
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    
    if(authStatus == AVAuthorizationStatusAuthorized) {
        [self presentCamera];
        return;
    } else if(authStatus == AVAuthorizationStatusNotDetermined){
        [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
            if(granted){
                [self presentCamera];
            }
        }];
        return;
    }
    
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:NSLocalizedString(@"Could not access camera", nil)
                                 message:NSLocalizedString(@"Camera access is not allowed. Check your settings.", nil)
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* okButton = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"OK", nil)
                               style:UIAlertActionStyleDefault
                               handler:nil];
    
    [alert addAction:okButton];
    [[NCUserInterfaceController sharedInstance] presentAlertViewController:alert];
}

- (void)presentCamera
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_imagePicker = [[UIImagePickerController alloc] init];
        self->_imagePicker.sourceType = UIImagePickerControllerSourceTypeCamera;
        self->_imagePicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:self->_imagePicker.sourceType];
        self->_imagePicker.delegate = self;
        [self presentViewController:self->_imagePicker animated:YES completion:nil];
    });
}

- (void)presentPhotoLibrary
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_imagePicker = [[UIImagePickerController alloc] init];
        self->_imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        self->_imagePicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:self->_imagePicker.sourceType];
        self->_imagePicker.delegate = self;
        [self presentViewController:self->_imagePicker animated:YES completion:nil];
    });
}

- (void)presentDocumentPicker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport];
        documentPicker.delegate = self;
        [self presentViewController:documentPicker animated:YES completion:nil];
    });
}

#pragma mark - Actions

- (void)sendSharedText
{
    [[NCAPIController sharedInstance] sendChatMessage:self.shareTextView.text toRoom:_room.token displayName:nil replyTo:-1 referenceId:nil forAccount:_account withCompletionBlock:^(NSError *error) {
        if (error) {
            [self.delegate shareConfirmationViewControllerDidFailed:self];
            NSLog(@"Failed to send shared item");
        } else {
            [self.delegate shareConfirmationViewControllerDidFinish:self];
            [[NCIntentController sharedInstance] donateSendMessageIntentForRoom:self->_room];
        }
        [self stopAnimatingSharingIndicator];
    }];
}

- (void)updateHudProgress
{
    if (!_hud) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat progress = 0;
        long items = 0;
        
        for (ShareItem *item in self->_shareItemController.shareItems) {
            progress += item.uploadProgress;
            items++;
        }
        
        self->_hud.progress = (progress / items);
    });
}

- (void)uploadAndShareFiles
{
    _hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
    _hud.mode = MBProgressHUDModeAnnularDeterminate;
    _hud.label.text = [NSString stringWithFormat:NSLocalizedString(@"Uploading %ld elements", nil), [self.shareItemController.shareItems count]];
    
    if ([self.shareItemController.shareItems count] == 1) {
        _hud.label.text = NSLocalizedString(@"Uploading 1 element", nil);
    }
    
    _uploadGroup = dispatch_group_create();
    _uploadFailed = NO;
    _uploadErrors = [[NSMutableArray alloc] init];
    
    for (ShareItem *item in self.shareItemController.shareItems) {
        NSLog(@"Uploading %@", item.fileURL);
        
        dispatch_group_enter(_uploadGroup);
        [self checkForUniqueNameAndUploadFileWithName:item.fileName withItem:item withOriginalName:YES];
    }
    
    dispatch_group_notify(_uploadGroup, dispatch_get_main_queue(),^{
        [self stopAnimatingSharingIndicator];
        [self->_hud hideAnimated:YES];
        
        [self->_shareItemController removeAllItems];
        
        // TODO: Do error reporting per item
        if (self->_uploadFailed) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"Upload failed", nil)
                                         message:[self->_uploadErrors componentsJoinedByString:@"\n"]
                                         preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"OK", nil)
                                       style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * _Nonnull action) {
                                            [self.delegate shareConfirmationViewControllerDidFailed:self];
                                        }];
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            [self.delegate shareConfirmationViewControllerDidFinish:self];
        }
    });
}

- (void)checkForUniqueNameAndUploadFileWithName:(NSString *)fileName withItem:(ShareItem *)item withOriginalName:(BOOL)isOriginalName
{
    NSString *fileServerPath = [self serverFilePathForFileName:fileName];
    NSString *fileServerURL = [self serverFileURLForFilePath:fileServerPath];
    
    [[NCCommunication shared] readFileOrFolderWithServerUrlFileName:fileServerURL depth:@"0" showHiddenFiles:NO requestBody:nil customUserAgent:nil addCustomHeaders:nil completionHandler:^(NSString *accounts, NSArray<NCCommunicationFile *> *files, NSData *responseData, NSInteger errorCode, NSString *errorDescription) {
        // File already exists
        if (errorCode == 0 && files.count == 1) {
            NSString *alternativeName = [self alternativeNameForFileName:fileName original:isOriginalName];
            [self checkForUniqueNameAndUploadFileWithName:alternativeName withItem:item withOriginalName:NO];
        // File does not exist
        } else if (errorCode == 404) {
            [self uploadFileToServerURL:fileServerURL withFilePath:fileServerPath withItem:item];
        } else {
            NSLog(@"Error checking file name: %@", errorDescription);
            
            self->_uploadFailed = YES;
            [self->_uploadErrors addObject:errorDescription];
            dispatch_group_leave(self->_uploadGroup);
        }
    }];
}

- (void)checkAttachmentFolderAndUploadFileToServerURL:(NSString *)fileServerURL withFilePath:(NSString *)filePath withItem:(ShareItem *)item
{
    NSString *attachmentFolderServerURL = [self attachmentFolderServerURL];
    [[NCCommunication shared] readFileOrFolderWithServerUrlFileName:attachmentFolderServerURL depth:@"0" showHiddenFiles:NO requestBody:nil customUserAgent:nil addCustomHeaders:nil completionHandler:^(NSString *accounts, NSArray<NCCommunicationFile *> *files, NSData *responseData, NSInteger errorCode, NSString *errorDescription) {
        // Attachment folder do not exist
        if (errorCode == 404) {
            [[NCCommunication shared] createFolder:attachmentFolderServerURL customUserAgent:nil addCustomHeaders:nil completionHandler:^(NSString *account, NSString *nose, NSDate *date, NSInteger errorCode, NSString *errorDescription) {
                if (errorCode == 0) {
                    [self uploadFileToServerURL:fileServerURL withFilePath:filePath withItem:item];
                }
            }];
        } else {
            NSLog(@"Error checking attachment folder: %@", errorDescription);
            
            self->_uploadFailed = YES;
            [self->_uploadErrors addObject:errorDescription];
            dispatch_group_leave(self->_uploadGroup);
        }
    }];
}

- (void)uploadFileToServerURL:(NSString *)fileServerURL withFilePath:(NSString *)filePath withItem:(ShareItem *)item
{
    [[NCCommunication shared] uploadWithServerUrlFileName:fileServerURL fileNameLocalPath:item.filePath dateCreationFile:nil dateModificationFile:nil customUserAgent:nil addCustomHeaders:nil progressHandler:^(NSProgress * progress) {
        item.uploadProgress = progress.fractionCompleted;
        [self updateHudProgress];
    } completionHandler:^(NSString *account, NSString *ocId, NSString *etag, NSDate *date, int64_t size, NSDictionary *allHeaderFields, NSInteger errorCode, NSString *errorDescription) {
        NSLog(@"Upload completed with error code: %ld", (long)errorCode);

        if (errorCode == 0) {
            [[NCAPIController sharedInstance] shareFileOrFolderForAccount:self->_account atPath:filePath toRoom:self->_room.token withCompletionBlock:^(NSError *error) {
                if (error) {
                    NSLog(@"Failed to send shared file");
                    
                    self->_uploadFailed = YES;
                    [self->_uploadErrors addObject:error.description];
                }
                
                dispatch_group_leave(self->_uploadGroup);
            }];
        } else if (errorCode == 404) {
            [self checkAttachmentFolderAndUploadFileToServerURL:fileServerURL withFilePath:filePath withItem:item];
        } else {
            self->_uploadFailed = YES;
            [self->_uploadErrors addObject:errorDescription];
            dispatch_group_leave(self->_uploadGroup);
        }
    }];
}

#pragma mark - Utils

- (NSString *)serverFilePathForFileName:(NSString *)fileName
{
    NSString *attachmentsFolder = _serverCapabilities.attachmentsFolder ? _serverCapabilities.attachmentsFolder : @"";
    return [NSString stringWithFormat:@"%@/%@", attachmentsFolder, fileName];
}

- (NSString *)attachmentFolderServerURL
{
    NSString *attachmentsFolder = _serverCapabilities.attachmentsFolder ? _serverCapabilities.attachmentsFolder : @"";
    return [NSString stringWithFormat:@"%@/%@%@", _account.server, _serverCapabilities.webDAVRoot, attachmentsFolder];
}

- (NSString *)serverFileURLForFilePath:(NSString *)filePath
{
    return [NSString stringWithFormat:@"%@/%@%@", _account.server, _serverCapabilities.webDAVRoot, filePath];
}

- (NSString *)alternativeNameForFileName:(NSString *)fileName original:(BOOL)isOriginal
{
    NSString *extension = [fileName pathExtension];
    NSString *nameWithoutExtension = [fileName stringByDeletingPathExtension];
    NSString *alternativeName = nameWithoutExtension;
    NSString *newSuffix = @" (1)";
    
    if (!isOriginal) {
        // Check if the name ends with ` (n)`
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@" \\((\\d+)\\)$" options:NSRegularExpressionCaseInsensitive error:&error];
        NSTextCheckingResult *match = [regex firstMatchInString:nameWithoutExtension options:0 range:NSMakeRange(0, nameWithoutExtension.length)];
        if ([match numberOfRanges] > 1) {
            NSRange suffixRange = [match rangeAtIndex: 0];
            NSInteger suffixNumber = [[nameWithoutExtension substringWithRange:[match rangeAtIndex: 1]] intValue];
            newSuffix = [NSString stringWithFormat:@" (%ld)", suffixNumber + 1];
            alternativeName = [nameWithoutExtension stringByReplacingCharactersInRange:suffixRange withString:@""];
        }
    }
    
    alternativeName = [alternativeName stringByAppendingString:newSuffix];
    alternativeName = [alternativeName stringByAppendingPathExtension:extension];
    
    return alternativeName;
}

#pragma mark - User Interface

- (void)startAnimatingSharingIndicator
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_sharingIndicatorView startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self->_sharingIndicatorView];
    });
}

- (void)stopAnimatingSharingIndicator
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_sharingIndicatorView stopAnimating];
        self.navigationItem.rightBarButtonItem = self->_sendButton;
    });
}

-(void)keyboardWillShow:(NSNotification *)notification
{
    // see https://stackoverflow.com/a/22719225/2512312
    NSDictionary *info = notification.userInfo;
    NSValue *value = info[UIKeyboardFrameEndUserInfoKey];
    
    CGRect rawFrame = [value CGRectValue];
    CGRect keyboardFrame = [self.view convertRect:rawFrame fromView:nil];
    
    [UIView animateWithDuration:0.3 animations:^{
        self.bottomSpacer.constant = keyboardFrame.size.height;
        [self.view layoutIfNeeded];
    }];
}

-(void)keyboardDidHide:(NSNotification *)notification
{
    [UIView animateWithDuration:0.3 animations:^{
        self.bottomSpacer.constant = 0;
        [self.view layoutIfNeeded];
    }];
}

- (void)updateToolbarForCurrentItem
{
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [UIView transitionWithView:self.itemToolbar duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            [self.cropItemButton setEnabled:item.isImage];
            [self.previewItemButton setEnabled:[QLPreviewController canPreviewItem:item.fileURL]];
            [self.addItemButton setEnabled:([self.shareItemController.shareItems count] < 5)];
        } completion:nil];
    }
    
    [self.removeItemButton setEnabled:([self.shareItemController.shareItems count] > 1)];
    [self.removeItemButton setTintColor:([self.shareItemController.shareItems count] > 1) ? nil : [UIColor clearColor]];
}

#pragma mark - UIImagePickerController Delegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    NSString *mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    
    if ([mediaType isEqualToString:@"public.image"]) {
        UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
        
        [self dismissViewControllerAnimated:YES completion:^{
            [self.shareItemController addItemWithImage:image];
            [self collectionViewScrollToEnd];
        }];
    } else if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *videoURL = [info objectForKey:UIImagePickerControllerMediaURL];
        
        [self dismissViewControllerAnimated:YES completion:^{
            [self.shareItemController addItemWithURL:videoURL];
            [self collectionViewScrollToEnd];
        }];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UIDocumentPickerViewController Delegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url
{
    [self shareDocumentsWithURLs:@[url] fromController:controller];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    [self shareDocumentsWithURLs:urls fromController:controller];
}

- (void)shareDocumentsWithURLs:(NSArray<NSURL *> *)urls fromController:(UIDocumentPickerViewController *)controller
{
    if (controller.documentPickerMode == UIDocumentPickerModeImport) {
        for (NSURL* url in urls) {
            [self.shareItemController addItemWithURL:url];
        }
        
        [self collectionViewScrollToEnd];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    
}

#pragma mark - ScrollView/CollectionView

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ShareConfirmationCollectionViewCell *cell = (ShareConfirmationCollectionViewCell *)[collectionView dequeueReusableCellWithReuseIdentifier:kShareConfirmationCellIdentifier forIndexPath:indexPath];
    ShareItem *item = [self.shareItemController.shareItems objectAtIndex:indexPath.row];
    
    // Setting placeholder here in case we can't generate any other preview
    [cell setPlaceHolderImage:item.placeholderImage];
    [cell setPlaceHolderText:item.fileName];

    // Check if we got an image
    UIImage *image = [self.shareItemController getImageFromItem:item];
    
    if (image) {
        // We're able to get an image directly from the fileURL -> use it
        [cell setPreviewImage:image];
    } else {
        // We need to generate our own preview/thumbnail here
        [self generatePreviewForCell:cell withCollectionView:collectionView withItem:item];
    }
    
    return cell;
}

- (void)generatePreviewForCell:(ShareConfirmationCollectionViewCell *)cell withCollectionView:(UICollectionView *)collectionView withItem:(ShareItem *)item
{
    if (@available(iOS 13.0, *)) {
        CGSize size = CGSizeMake(collectionView.bounds.size.width, collectionView.bounds.size.height);
        CGFloat scale = [UIScreen mainScreen].scale;
        
        // updateHandler might be called multiple times, starting from low quality representation to high-quality
        QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:item.fileURL size:size scale:scale representationTypes:(QLThumbnailGenerationRequestRepresentationTypeLowQualityThumbnail | QLThumbnailGenerationRequestRepresentationTypeThumbnail)];
        [QLThumbnailGenerator.sharedGenerator generateRepresentationsForRequest:request updateHandler:^(QLThumbnailRepresentation * _Nullable thumbnail, QLThumbnailRepresentationType type, NSError * _Nullable error) {
            if (error) {
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [cell setPreviewImage:thumbnail.UIImage];
            });
        }];
    }
}

- (NSInteger)collectionView:(nonnull UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return [self.shareItemController.shareItems count];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return CGSizeMake(collectionView.bounds.size.width, collectionView.bounds.size.height);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self previewCurrentItem];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self updatePageControlPage];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    [self updatePageControlPage];
}

- (void)collectionViewScrollToEnd
{
    [self scrollToItem:self.shareItemController.shareItems.lastObject animated:YES];
}

- (void)scrollToItem:(ShareItem *)item animated:(BOOL)animated
{
    if (!item) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger indexForItem = [self.shareItemController.shareItems indexOfObject:item];
        
        if (indexForItem != NSNotFound) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForItem:indexForItem inSection:0];
            [self.shareCollectionView scrollToItemAtIndexPath:indexPath
                                             atScrollPosition:UICollectionViewScrollPositionNone
                                                     animated:animated];
        }
    });
}

- (ShareItem *)getCurrentShareItem
{
    NSInteger currentIndex = self.shareCollectionView.contentOffset.x / self.shareCollectionView.frame.size.width;
    
    if (currentIndex >= [self.shareItemController.shareItems count]) {
        return nil;
    }
    
    return [self.shareItemController.shareItems objectAtIndex:currentIndex];
}

#pragma mark - PageControl

- (IBAction)pageControlValueChanged:(id)sender
{
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:self.pageControl.currentPage inSection:0];
    [self.shareCollectionView scrollToItemAtIndexPath:indexPath
                                     atScrollPosition:UICollectionViewScrollPositionNone
                                             animated:YES];
}

- (void)updatePageControlPage
{
    // see: https://stackoverflow.com/a/46181277/2512312
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pageControl.currentPage = self.shareCollectionView.contentOffset.x / self.shareCollectionView.frame.size.width;
        
        [self updateToolbarForCurrentItem];
    });
}

#pragma mark - PreviewController

- (void)previewCurrentItem
{
    ShareItem *item = [self getCurrentShareItem];
    
    // Only open preview if there's an actual item and it can be previewed
    if (!item || !item.fileURL || ![QLPreviewController canPreviewItem:item.fileURL]) {
        return;
    }
    
    QLPreviewController * preview = [[QLPreviewController alloc] init];
    preview.dataSource = self;
    preview.delegate = self;
    
    preview.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
    preview.navigationController.navigationBar.barTintColor = [NCAppBranding themeColor];
    preview.tabBarController.tabBar.tintColor = [NCAppBranding themeColor];

    UIColor *themeColor = [NCAppBranding themeColor];
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = themeColor;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
        preview.navigationItem.standardAppearance = appearance;
        preview.navigationItem.compactAppearance = appearance;
        preview.navigationItem.scrollEdgeAppearance = appearance;
    }

    [self.navigationController pushViewController:preview animated:YES];
}

- (nonnull id<QLPreviewItem>)previewController:(nonnull QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    // Don't use index here, as this relates to numberOfPreviewItems
    // When we have numberOfPreviewItems > 1 this will show an additional list of items
    ShareItem *item = [self getCurrentShareItem];
    
    if (item && item.fileURL) {
        return item.fileURL;
    }
    
    return nil;
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller
{
    return 1;
}

- (QLPreviewItemEditingMode)previewController:(QLPreviewController *)controller editingModeForPreviewItem:(id<QLPreviewItem>)previewItem  API_AVAILABLE(ios(13.0)) {
    return QLPreviewItemEditingModeCreateCopy;
}

- (void)previewController:(QLPreviewController *)controller didSaveEditedCopyOfPreviewItem:(id<QLPreviewItem>)previewItem atURL:(NSURL *)modifiedContentsURL {
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [self.shareItemController updateItem:item withURL:modifiedContentsURL];
    }
}


#pragma mark - ShareItemController Delegate
 
- (void)shareItemControllerItemsChanged:(nonnull ShareItemController *)shareItemController {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger shareItemCount = [shareItemController.shareItems count];
        
        if (shareItemCount == 0) {
            if (self.extensionContext) {
                NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:nil];
                [self.extensionContext cancelRequestWithError:error];
            } else {
                [self dismissViewControllerAnimated:YES completion:nil];
            }
        } else {
            [self.shareCollectionView reloadData];
            
            // Make sure all changes are full populated before we update our ui elements
            [self.shareCollectionView layoutIfNeeded];
            [self updateToolbarForCurrentItem];
            self.pageControl.numberOfPages = [shareItemController.shareItems count];
        }
    });
}

#pragma mark - TOCropViewController Delegate

- (void)cropViewController:(TOCropViewController *)cropViewController didCropToImage:(UIImage *)image withRect:(CGRect)cropRect angle:(NSInteger)angle
{
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [self.shareItemController updateItem:item withImage:image];
        
        // Fixes bug on iPad where collectionView is scrolled between two pages
        [self scrollToItem:item animated:YES];
    }

    // Fixes weird iOS 13 bug: https://github.com/TimOliver/TOCropViewController/issues/365
    cropViewController.transitioningDelegate = nil;
    [cropViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)cropViewController:(TOCropViewController *)cropViewController didFinishCancelled:(BOOL)cancelled
{
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        // Fixes bug on iPad where collectionView is scrolled between two pages
        [self scrollToItem:item animated:YES];
    }
    
    // Fixes weird iOS 13 bug: https://github.com/TimOliver/TOCropViewController/issues/365
    cropViewController.transitioningDelegate = nil;
    [cropViewController dismissViewControllerAnimated:YES completion:nil];
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
