/*
 Copyright 2014 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "RoomViewController.h"

#import "MatrixHandler.h"

@interface RoomViewController ()

@property (strong, nonatomic) MXRoomData *mxRoomData;

@end

@implementation RoomViewController

#pragma mark - Managing the detail item

- (void)setDetailItem:(NSString*)roomId {
    _roomId = roomId;
    
    // Update the view.
    [self configureView];
}

- (void)configureView {
    // Update the user interface for the detail item.
    if (self.roomId) {
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        self.mxRoomData = [[mxHandler mxData] getRoomData:self.roomId];
        self.detailDescriptionLabel.text = [mxHandler displayTextFor:self.mxRoomData.lastMessage inDetailMode:NO];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    [self configureView];
}

- (void)dealloc {
    _mxRoomData = nil;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
