import 'package:flutter/material.dart';

import '../models.dart';

/// 性别展示（v2.0.61 / G4：有则显示、无则中性，绝不猜）。
///
/// 标准 Emby 的 `People[]` / Person item 没有性别字段，[CastMember.gender]
/// 绝大多数情况是 null。这里把「怎么把性别画出来」收敛到一处，详情页演员
/// 胶囊、演员详情资料卡共用，避免任何一处再把 ♀ 当默认装饰符号写死。

// 与详情页 _Cap 行的配色一致（紫 / 蓝 / 中性灰）
const Color _kFemale = Color(0xFFB98CFF);
const Color _kMale = Color(0xFF6FA8FF);
const Color _kNeutral = Color(0xFF7E8DA6);

/// 显式性别文案：有明确性别才给「女 / 男」，否则返回 null 让调用方**隐藏**
/// 该字段，绝不摆「未知 / —」把性别信息做成一排错的占位。
String? genderLabel(String? gender) {
  if (gender == kGenderFemale) return '女';
  if (gender == kGenderMale) return '男';
  return null;
}

/// 胶囊 / 徽标前缀：female → ♀，male → ♂，未知 → 中性人物图标。
/// 未知走中性图标而不是省略，是为了在每个演员位置都有一个「这里没数据」
/// 的诚实占位，同时不会像旧版那样暗示「这是女性」。
Widget genderLeading(String? gender, {double size = 12}) {
  switch (gender) {
    case kGenderFemale:
      return Text('♀', style: TextStyle(fontSize: size, color: _kFemale));
    case kGenderMale:
      return Text('♂', style: TextStyle(fontSize: size, color: _kMale));
    default:
      return Icon(Icons.person_outline_rounded, size: size, color: _kNeutral);
  }
}
