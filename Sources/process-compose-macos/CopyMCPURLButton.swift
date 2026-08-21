import AppKit
import ProcessComposeCore
import SwiftUI

/// Both the toolbar readout's context menu and the Process menu offer this action.
struct CopyMCPURLButton: View {
	let mcpModel: MCPServerViewModel

	var body: some View {
		Button("Copy MCP URL") {
			guard let url = mcpModel.url else { return }
			NSPasteboard.copy(url.absoluteString)
		}
		.disabled(mcpModel.url == nil)
	}
}
