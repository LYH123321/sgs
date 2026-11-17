/**
 * Copyright (c) 2006-2024 LOVE Development Team
 * Modifications for SGS Android port: GPL-3.0
 */
package org.love2d.android;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

import androidx.annotation.Nullable;

import java.util.Objects;

public class IntentReceiverActivity extends Activity {
    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Intent mainIntent = getIntent();
        Intent intent = new Intent(this, GameActivity.class);

        if (Objects.equals(mainIntent.getAction(), Intent.ACTION_SEND)) {
            Uri uri = mainIntent.getParcelableExtra(Intent.EXTRA_STREAM);
            intent.setData(uri);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        }

        startActivity(intent);
        finish();
    }
}
