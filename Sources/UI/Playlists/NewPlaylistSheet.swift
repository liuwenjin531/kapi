import SwiftUI
import PhotosUI

/// 新建歌单：左上关闭、右上确认、封面占位（可选图）、名称输入框。
struct NewPlaylistSheet: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var showPicker = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var preview: UIImage?
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // PhotosPicker 走系统选图器，不需要相册权限
                Button { showPicker = true } label: { cover }
                    .buttonStyle(.plain)
                    .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
                TextField("歌单名称", text: $name)
                    .font(.system(size: 17))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(create)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Theme.sheet)
            .navigationTitle("新建歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: create)
                        .disabled(trimmed.isEmpty)
                }
            }
            .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    imageData = data
                    preview = data.flatMap(UIImage.init(data:))
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.medium])
    }

    private var cover: some View {
        ZStack {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.card
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 30))
                    Text("选择封面")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: coverRadius(for: 140), style: .continuous))
        .accessibilityLabel("选择封面")
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        do {
            let playlist = try store.create(name: trimmed)
            // 封面失败不回滚歌单：歌单已建好，封面可以之后在详情页再换
            if let imageData { try? store.setCover(playlist.id, imageData: imageData) }
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}

#Preview("新建歌单") {
    Color.clear.sheet(isPresented: .constant(true)) {
        NewPlaylistSheet().environment(PlaylistStore())
    }
}
