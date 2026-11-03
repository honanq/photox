// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>

// Called only from Photos' lifecycle; never starts or opens an app.
void HAStartAlbumInventory(void);
void HARefreshAlbumInventory(void);
// Reject new refresh work, drain the serial worker, then finish on main.
void HAStopAlbumInventory(dispatch_block_t completion);
