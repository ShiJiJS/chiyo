#ifndef RUNNER_NOTIFICATION_QUEUE_H_
#define RUNNER_NOTIFICATION_QUEUE_H_

#include <deque>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <utility>

struct NotificationMessage {
  std::string request_id;
  bool test = false;
  std::uint32_t native_id = 0;
};

enum class BalloonEvent { shown, hidden, timedOut, clicked };

// Native callbacks carry an icon ID, not the request ID. Every send therefore
// uses a fresh ID and the native sender must register that ID with the Shell.
class NotificationQueue {
 public:
  using Sender = std::function<bool(const NotificationMessage&)>;
  using Reply = std::function<void(bool)>;
  explicit NotificationQueue(Sender sender) : sender_(std::move(sender)) {}

  void Enqueue(NotificationMessage message, Reply reply) {
    if (pending_.size() >= 64) { reply(false); return; }
    pending_.push_back({std::move(message), std::move(reply)});
    Pump();
  }

  std::optional<NotificationMessage> OnBalloonEvent(
      BalloonEvent event, std::uint32_t native_id) {
    if (!active_ || active_->native_id != native_id ||
        event == BalloonEvent::shown) return std::nullopt;
    auto ended = std::move(active_);
    active_.reset();
    Pump();
    return event == BalloonEvent::clicked ? ended : std::nullopt;
  }

  void Reset() {
    active_.reset();
    auto discarded = std::move(pending_);
    pending_.clear();
    for (auto& entry : discarded) entry.reply(false);
  }

 private:
  struct Pending { NotificationMessage message; Reply reply; };
  void Pump() {
    if (pumping_) return;
    pumping_ = true;
    while (!active_ && !pending_.empty()) {
      auto entry = std::move(pending_.front());
      pending_.pop_front();
      // VERSION_4 callbacks expose only 16 bits. Never wrap/reuse even after
      // Reset: a delayed callback could otherwise acquire a new request.
      // IDs below 0x1000 are reserved for the persistent generic tray icon.
      if (next_native_id_ > 0xffff) { entry.reply(false); continue; }
      entry.message.native_id = next_native_id_++;
      active_ = entry.message;
      const bool accepted = sender_(entry.message);
      if (!accepted) active_.reset();
      entry.reply(accepted);
    }
    pumping_ = false;
  }
  Sender sender_;
  std::deque<Pending> pending_;
  std::optional<NotificationMessage> active_;
  bool pumping_ = false;
  std::uint32_t next_native_id_ = 0x1000;
};

#endif  // RUNNER_NOTIFICATION_QUEUE_H_
