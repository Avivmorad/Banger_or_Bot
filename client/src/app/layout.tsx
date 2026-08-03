import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { Analytics } from "@vercel/analytics/next";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL(
    process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000",
  ),
  title: {
    default: "Banger or Bot",
    template: "%s · Banger or Bot",
  },
  description:
    "Listen to the track, decide if it was made by a human or AI, and beat your friends to the answer.",
  applicationName: "Banger or Bot",
  keywords: ["music game", "multiplayer", "AI music", "party game"],
  openGraph: {
    type: "website",
    title: "Banger or Bot",
    description:
      "Can you hear the difference between human music and an AI-made track?",
    siteName: "Banger or Bot",
  },
  twitter: {
    card: "summary_large_image",
    title: "Banger or Bot",
    description: "The AI music showdown for you and your friends.",
  },
};

export const viewport: Viewport = {
  colorScheme: "dark",
  themeColor: "#090a0d",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      data-scroll-behavior="smooth"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body>
        {children}
        <Analytics />
      </body>
    </html>
  );
}
