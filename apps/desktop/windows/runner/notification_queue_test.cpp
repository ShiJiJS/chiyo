#include "notification_queue.h"
#include <iostream>
#include <stdexcept>
#include <vector>

static void Check(bool condition) {
  if (!condition) throw std::runtime_error("notification delivery contract failed");
}

int main() {
  try {
    std::vector<std::string> sent;
    std::vector<std::pair<std::string, bool>> replies;
    std::uint32_t current_id = 0;
    NotificationQueue queue([&](const NotificationMessage& message) {
      current_id = message.native_id;
      sent.push_back(message.test ? "test" : message.request_id);
      return message.request_id != "fail";
    });
    const auto enqueue = [&](std::string id, bool test = false) {
      queue.Enqueue({id, test}, [&, id](bool accepted) { replies.emplace_back(id, accepted); });
    };
    const auto event = [&](BalloonEvent kind) {
      return queue.OnBalloonEvent(kind, current_id);
    };
    enqueue("A"); enqueue("fail"); enqueue("B"); enqueue("", true); enqueue("C");
    Check(sent == std::vector<std::string>{"A"});
    Check(replies.size() == 1 && replies[0].second);
    event(BalloonEvent::shown);
    Check(sent.size() == 1);
    auto clicked = event(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "A");
    Check(sent == std::vector<std::string>({"A", "fail", "B"}));
    Check(replies.size() == 3 && !replies[1].second && replies[2].second);
    clicked = event(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "B");
    Check(sent.back() == "test");
    clicked = event(BalloonEvent::clicked);
    Check(clicked && clicked->test && clicked->request_id.empty());
    Check(sent.back() == "C");
    Check(!event(BalloonEvent::timedOut));
    Check(!event(BalloonEvent::clicked));
    enqueue("quiet"); enqueue("D");
    Check(!event(BalloonEvent::hidden));
    clicked = event(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "D");
    enqueue("E"); enqueue("F");
    queue.Reset();
    Check(replies.back() == std::make_pair(std::string("F"), false));
    Check(!event(BalloonEvent::clicked));
    enqueue("G");
    clicked = event(BalloonEvent::clicked);
    Check(clicked && clicked->request_id == "G");
    // The live Windows probe observed two timeout callbacks for one send.
    // A repeated terminal callback must not consume the next queued request.
    std::vector<std::string> duplicate_sent;
    std::vector<std::uint32_t> duplicate_ids;
    NotificationQueue duplicates([&](const NotificationMessage& message) {
      duplicate_sent.push_back(message.request_id);
      duplicate_ids.push_back(message.native_id);
      return true;
    });
    duplicates.Enqueue({"old"}, [](bool) {});
    duplicates.Enqueue({"next"}, [](bool) {});
    duplicates.Enqueue({"later"}, [](bool) {});
    const auto old_id = duplicate_ids.front();
    duplicates.OnBalloonEvent(BalloonEvent::shown, old_id);
    duplicates.OnBalloonEvent(BalloonEvent::timedOut, old_id);
    duplicates.OnBalloonEvent(BalloonEvent::timedOut, old_id);
    Check(duplicate_sent == std::vector<std::string>({"old", "next"}));
    Check(!duplicates.OnBalloonEvent(BalloonEvent::clicked, old_id));
    Check(!duplicates.OnBalloonEvent(BalloonEvent::hidden, old_id));
    Check(!duplicates.OnBalloonEvent(BalloonEvent::clicked, 1));
    clicked = duplicates.OnBalloonEvent(BalloonEvent::clicked, duplicate_ids.back());
    Check(clicked && clicked->request_id == "next");
    Check(duplicate_sent.back() == "later");
    const auto retired_id = duplicate_ids.back();
    duplicates.Reset();
    duplicates.Enqueue({"after-reset"}, [](bool) {});
    Check(duplicate_ids.back() > retired_id);
    Check(!duplicates.OnBalloonEvent(BalloonEvent::clicked, retired_id));
    clicked = duplicates.OnBalloonEvent(BalloonEvent::clicked, duplicate_ids.back());
    Check(clicked && clicked->request_id == "after-reset");
    // Exhausting the native callback space must reject, not alias old IDs.
    unsigned sends = 0;
    std::uint32_t exhausted_id = 0;
    bool accepted = false;
    NotificationQueue bounded([&](const NotificationMessage& message) {
      ++sends; exhausted_id = message.native_id; return true;
    });
    for (std::uint32_t id = 0x1000; id <= 0xffff; ++id) {
      bounded.Enqueue({"bounded"}, [&](bool value) { accepted = value; });
      Check(accepted && exhausted_id == id);
      Check(bounded.OnBalloonEvent(BalloonEvent::clicked, id).has_value());
    }
    const auto sent_before = sends;
    bounded.Enqueue({"overflow"}, [&](bool value) { accepted = value; });
    Check(!accepted && sends == sent_before);
    bounded.Reset();
    bounded.Enqueue({"still-exhausted"}, [&](bool value) { accepted = value; });
    Check(!accepted && sends == sent_before);
    std::cout << "Native notification request/test queue contract passed.\n";
    return 0;
  } catch (const std::exception&) {
    std::cerr << "Native notification request/test queue contract failed.\n";
    return 1;
  }
}
