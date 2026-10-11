import UIKit

final class ViewController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launches.txt")
        let previous = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0) } ?? 0
        let count = previous + 1
        try? String(count).write(to: url, atomically: true, encoding: .utf8)

        let label = UILabel(frame: view.bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.text = "Apple Auto\n\niOS \(UIDevice.current.systemVersion)\n"
            + "\(Int(view.bounds.width))×\(Int(view.bounds.height)) pt\n"
            + "launch #\(count)"
        view.addSubview(label)
    }
}
