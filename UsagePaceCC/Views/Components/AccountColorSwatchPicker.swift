//
//  AccountColorSwatchPicker.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-27.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import SwiftUI

// MARK: - 账户颜色色板选择器

/// 紧凑的水平色板选择器：为账户的固定调色板（`AccountColor`）提供逐个可点选的色块，
/// 当前选中项以描边高亮，而非使用任意 RGB 的 `ColorPicker`。
struct AccountColorSwatchPicker: View {
    @Binding var selection: AccountColor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AccountColor.allCases, id: \.self) { color in
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(Color.primary, lineWidth: selection == color ? 2 : 0)
                    )
                    .onTapGesture {
                        selection = color
                    }
            }
        }
    }
}
