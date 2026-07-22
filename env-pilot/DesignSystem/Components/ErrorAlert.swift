import SwiftUI

extension View {
    /// 공통 에러 alert — `@State var errorMessage: String?`에 연결. 닫으면 nil로 복원.
    func errorAlert(_ message: Binding<String?>, title: String = "오류") -> some View {
        alert(title,
              isPresented: Binding(get: { message.wrappedValue != nil },
                                   set: { if !$0 { message.wrappedValue = nil } }),
              presenting: message.wrappedValue) { _ in
            Button("확인") {}
        } message: { text in
            Text(text)
        }
    }
}
